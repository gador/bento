#!/bin/sh

if test -f config.sh
then
    . ./config.sh
else
    echo "You are missing config.sh"
    exit 2
fi

# FUNCTION LIBRARIES
user_exists() {
    user="$1"
    if ! id "${user}" >/dev/null 2>/dev/null
    then
        echo "you need a system user in your fleet for ${user}"
        exit 3
    fi
}

display_table() {
    size_hostname=$1
    machine=$2
    local_version=$3
    remote_version=$4
    state=$5
    time=$6

    printf "%${size_hostname}s %15s %18s %20s %40s\n" \
        "$machine" "$local_version" "$remote_version" "$state" "$time"
}

build_config()
{
    SOURCES=$1
    COMMAND="$2"
    SUDO="$3"
    NAME="$4"

    user_exists "${NAME}"

    SUCCESS=0
    TMP="$(mktemp -d /tmp/bento-build.XXXXXXXXXXXX)"
    TMPLOG="$(mktemp /tmp/bento-build-log.XXXXXXXXXXXX)"
    rsync -aL "$SOURCES/" "$TMP/"

    SECONDS=0
    cd "$TMP" || exit 5

    if test -f "flake.nix"
    then
        # add files to a git repo
        test -d .git || git init >/dev/null 2>/dev/null
        git add . >/dev/null

        $SUDO nixos-rebuild "${COMMAND}" --flake ".#${NAME}" 2>"${TMPLOG}" >"${TMPLOG}"
    else
        $SUDO nixos-rebuild "${COMMAND}" --no-flake -I nixos-config="$TMP/configuration.nix" 2>"${TMPLOG}" >"${TMPLOG}"
    fi
    if [ $? -eq 0 ]; then printf "success " ; else printf "failure " ; BAD_HOSTS="${NAME} ${BAD_HOSTS}" ; SUCCESS=$(( SUCCESS + 1 )) ; cat "${TMPLOG}" ; fi
    ELAPSED=$(elapsed_time $SECONDS)
    printf "($ELAPSED)"

    # systems not using flakes are not reproducible
    # without pinning the channels, skip this
    if [ -f "flake.nix" ] && [ "${COMMAND}" = "build" ]
    then
        touch "${OLDPWD}/../states.txt"
        VERSION="$(readlink -f result | tr -d '\n' | sed 's,/nix/store/,,')"
        printf " %s" "${VERSION}"
        sed -i "/^${NAME}/d" "$OLDPWD/../states.txt" >/dev/null
        echo "${NAME}=${VERSION}" >> "$OLDPWD/../states.txt"
    fi
    echo ""

    cd - >/dev/null || exit 5
    rm -fr "$TMP"

    return "${SUCCESS}"
}

deploy_files() {
    sources="$1"
    user="$2"
    config="$3"
    if [ -n "${config}" ]
    then
        dest="${config}"
    else
        dest="${sources}"
    fi

    user_exists "${dest}"

    printf "Copying ${dest}: "

    # we only want directories
    if [ -d "$i" ]
    then

        STAGING_DIR="$(mktemp -d /tmp/bento-staging-dispatch.XXXXXXXXXXXXXX)"

        # sftp chroot requires the home directory to be owned by root
        install -d -o root   -g sftp_users -m 755 "${STAGING_DIR}"
        install -d -o root   -g sftp_users -m 755 "${STAGING_DIR}/${sources}"
        install -d -o root   -g sftp_users -m 755 "${STAGING_DIR}/${sources}/config"
        install -d -o "${user}" -g sftp_users -m 755 "${STAGING_DIR}/${sources}/logs"

        # copy files in the chroot
        rsync --delete -rltgoDL "$sources/" "${STAGING_DIR}/${sources}/config/"

        # create the script that will check for updates
        cat > "${STAGING_DIR}/${sources}/config/update.sh" <<EOF
#!/bin/sh

install -d -o root -g root -m 700 /var/bento
cd /var/bento || exit 5
touch .state

# don't get stuck if we change the host
ssh-keygen -F "${REMOTE_IP}" >/dev/null || ssh-keyscan "${REMOTE_IP}" >> /root/.ssh/known_hosts

STATEFILE="\$(mktemp /tmp/bento-state.XXXXXXXXXXXXXXXX)"
echo "ls -l last_change_date" | sftp ${user}@${REMOTE_IP} >"\${STATEFILE}"

if [ \$? -ne 0 ]
then
    echo "There is certainly a network problem with ${REMOTE_IP}"
    echo "Aborting"
    rm "\${STATEFILE}"
    exit 1
fi

STATE="\$(cat "\${STATEFILE}")"
CURRENT_STATE="\$(cat /var/bento/.state)"

if [ "\$STATE" = "\$CURRENT_STATE" ]
then
    echo "no update required"
else
    echo "update required"
    sftp ${user}@${REMOTE_IP}:/config/bootstrap.sh .
    /bin/sh bootstrap.sh
    echo "\${STATE}" > "/var/bento/.state"
fi
rm "\${STATEFILE}"
EOF

        # script used to download changes and rebuild
        # also used to run it manually the first time to configure the system
        cat > "${STAGING_DIR}/${sources}/config/bootstrap.sh" <<EOF
#!/bin/sh

# accept the remote ssh fingerprint if not already known
ssh-keygen -F "${REMOTE_IP}" >/dev/null || ssh-keyscan "${REMOTE_IP}" >> /root/.ssh/known_hosts

install -d -o root -g root -m 700 /var/bento
cd /var/bento || exit 5

find . -maxdepth 1 -type d -exec rm -fr {} \;
find . -maxdepth 1 -type f -not -name .state -and -not -name update.sh -and -not -name bootstrap.sh -exec rm {} \;

printf "%s\n" "cd config" "get -R ." | sftp -r ${user}@${REMOTE_IP}:

# required by flakes
test -d .git || git init
git add .

# check the current build if it exists
OSVERSION="\$(basename \$(readlink -f /nix/var/nix/profiles/system))"

LOGFILE=\$(mktemp /tmp/build-log.XXXXXXXXXXXXXXXXXXXX)

SUCCESS=2
if test -f flake.nix
then
    nixos-rebuild build --flake .#${dest}
else
    export NIX_PATH=/root/.nix-defexpr/channels:nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/var/bento/configuration.nix:/nix/var/nix/profiles/per-user/root/channels
    nixos-rebuild build --no-flake --upgrade 2>&1 | tee \$LOGFILE
fi

SUCCESS=\$?
if [ "\${SUCCESS}" -eq 0 ]
then
    if [ ! "\${OSVERSION}" = "\$(basename \$(readlink -f result))" ]
    then
        if test -f flake.nix
        then
            nixos-rebuild switch --flake .#${dest} 2>&1 | tee \$LOGFILE
        else
            nixos-rebuild switch --no-flake --upgrade 2>&1 | tee -a \$LOGFILE
        fi
        SUCCESS=\$(( SUCCESS + \$? ))

        # did we change the OSVERSION?
        NEWVERSION="\$(basename \$(readlink -f /nix/var/nix/profiles/system))"
        if [ "\${OSVERSION}" = "\${NEWVERSION}" ]
        then
            SUCCESS=1
        else
            OSVERSION="\${NEWVERSION}"
        fi
    else
        # we want to report a success log
        # no configuration changed but Bento did
        SUCCESS=0
    fi
fi

# nixos-rebuild doesn't report an error in case of lack of disk space on /boot
# see #189966
if [ "\$SUCCESS" -eq 0 ]
then
    if grep "No space left" "\$LOGFILE"
    then
        SUCCESS=1
        # we don't want to skip a rebuild next time
        rm result
    fi
fi

# rollback if something is wrong
# we test connection to the sftp server
echo "ls -l last_change_date" | sftp ${user}@${REMOTE_IP} >"\${LOGFILE}"
if [ "\$?" -ne 0 ];
then
    nixos-rebuild --rollback switch
    SUCCESS=255
    OSVERSION="\$(basename \$(readlink -f /nix/var/nix/profiles/system))"
fi

gzip -9 \$LOGFILE
if [ "\$SUCCESS" -eq 0 ]
then
    echo "put \${LOGFILE}.gz /logs/\$(date +%Y%m%d-%H%M)_\${OSVERSION}_success.log.gz" | sftp ${user}@${REMOTE_IP}:
else
    # check if we did a rollback
    if [ "\$SUCCESS" -eq 255 ]
    then
        echo "put \${LOGFILE}.gz /logs/\$(date +%Y%m%d-%H%M)_\${OSVERSION}_rollback.log.gz" | sftp ${user}@${REMOTE_IP}:
    else
        echo "put \${LOGFILE}.gz /logs/\$(date +%Y%m%d-%H%M)_\${OSVERSION}_failure.log.gz" | sftp ${user}@${REMOTE_IP}:
    fi
fi
rm "\${LOGFILE}.gz"
EOF

        # to make flakes using caching, we must avoid repositories to change everytime
        # we must ignore files that change everytime
        cat > "${STAGING_DIR}/${sources}/config/.gitignore" <<EOF
bootstrap.sh
update.sh
.state
result
last_change_date
EOF

        # only distribute changes if they changed
        # this avoids bumping the time and trigger a rebuild for nothing

        diff -r "${STAGING_DIR}/${sources}/config/" "${CHROOT_DIR}/${dest}/config/" >/dev/null
        CHANGES=$?

        if [ "$CHANGES" -ne 0 ]
        then
            if [ -n "${config}" ]
            then
                build_config "${STAGING_DIR}/${sources}/config/" "build" "" "${config}"
            else
                build_config "${STAGING_DIR}/${sources}/config/" "build" "" "${sources}"
            fi
            echo " update required"
            # copy files in the chroot
            install -d -o root -g sftp_users -m 755 "${CHROOT_DIR}"
            install -d -o root -g sftp_users -m 755 "${CHROOT_DIR}/${dest}"
            install -d -o root -g sftp_users -m 755 "${CHROOT_DIR}/${dest}/config"
            install -d -o "${dest}" -g sftp_users -m 755 "${CHROOT_DIR}/${dest}/logs"
            rsync --delete -rltgoDL "${STAGING_DIR}/${sources}/config/" "${CHROOT_DIR}/${dest}/config/"
            touch "${CHROOT_DIR}/${dest}/last_change_date"
        else
            echo " no changes"
        fi

        rm -fr "${STAGING_DIR}"
        fi
}

elapsed_time() {
    RAW="$1"

    DAYS=$(( RAW / (24 * 60 * 60) ))
    RAW=$(( RAW % (24 * 60 * 60) ))

    HOURS=$(( RAW / (60 * 60) ))
    RAW=$(( RAW % (60 * 60) ))

    MINUTES=$(( RAW / 60 ))
    RAW=$(( RAW % 60 ))

    SEC=$RAW

    if [ "$DAYS" -ne 0 ]; then DURATION="${DAYS}d " ; fi
    if [ "$HOURS" -ne 0 ]; then DURATION="${DURATION}${HOURS}h " ; fi
    if [ "$MINUTES" -ne 0 ]; then DURATION="${DURATION}${MINUTES}m " ; fi
    if [ "$SEC" -ne 0 ]; then DURATION="${DURATION}${SEC}s" ; fi

    if [ -z "$DURATION" ]; then DURATION="0s" ; fi

    echo "$DURATION"
}




# CODE BEGINS HERE

cd hosts

# load all hosts or the one defined in environment variable NAME
FLAKES=$(
for flakes in $(find . -name flake.nix)
do
    TARGET="$(dirname $flakes)"
    nix flake show --json "path:$TARGET" | jq -r '.nixosConfigurations | keys[]'
done
)

if [ -z "${NAME}" ]
then
    NAME=*
    PRETTY_OUT_COLUMN=$( ( ls -1 ; echo $FLAKES ) | awk '{ if(length($1) > max) { max = length($1) }} END { print max }')
else
    MATCH=$(echo "$FLAKES" | awk -v name="${NAME}" 'BEGIN { sum = 0 } name == $1 { sum=sum+1 } END { print sum }')
    if [ "$MATCH" -ne 1 ]
    then
        echo "Found ${MATCH} system with this name"
        exit 2
    else
        for flakes in $(find . -name flake.nix)
        do
            TARGET="$(dirname $flakes)"
            FLAKES_IN_DIR=$(nix flake show --json "path:$TARGET" | jq -r '.nixosConfigurations | keys[]')
            if echo "${FLAKES_IN_DIR}" | grep "^${NAME}$" >/dev/null
            then
                # store the configuration name
                SINGLE_FLAKE="${NAME}"
                # store the directory containing it
                NAME="$(basename ${TARGET})"
            fi
        done
    fi
fi

if [ "$1" = "build" ]
then
    if [ -z "$2" ]
    then
      COMMAND="dry-build"
    else
      COMMAND="$2"
    fi

    if [ "$COMMAND" = "switch" ] || [ "$COMMAND" = "test" ]
    then

        # we only allow these commands if you have only one name
        if [ -n "$NAME" ]
        then
            SUDO="sudo"
            echo "you are about to $COMMAND $NAME, are you sure? Ctrl+C to abort"
            read a
        else
            echo "you can't use $COMMAND without giving a single configuration to use with variable NAME"
        fi

    else # not using switch or test
        SUDO=""
    fi
    for i in $NAME
    do
        test -d "$i" || continue
        if [ -f "$i/flake.nix" ]
        then
            for host in $(nix flake show --json "path:${i}" | jq -r '.nixosConfigurations | keys[]')
            do
                test -n "${SINGLE_FLAKE}" && ! [ "$host" = "${SINGLE_FLAKE}" ] && continue
                printf "%${PRETTY_OUT_COLUMN}s " "${host}"
                build_config "$i" "$COMMAND" "$SUDO" "$host"
            done
        else
            printf "%${PRETTY_OUT_COLUMN}s " "${i}"
            build_config "$i" "$COMMAND" "$SUDO" "$i"
        fi
    done
    exit 0
fi

if [ "$1" = "deploy" ]
then
    if [ "$(id -u)" -ne 0 ]
    then
      echo "you need to be root to run this script"
      exit 1
    fi

    for i in $NAME
    do
        if [ -f "$i/flake.nix" ]
        then
            for host in $(nix flake show --json "path:${i}" | jq -r '.nixosConfigurations | keys[]')
            do
                test -n "${SINGLE_FLAKE}" && ! [ "$host" = "${SINGLE_FLAKE}" ] && continue
                deploy_files "$i" "${host}" "${host}"
            done
        else
            deploy_files "$i" "$i"
        fi

    done

    if [ -f ../states.txt ]
    then
        cp ../states.txt "${CHROOT_DIR}/states.txt"
    fi
fi

if [ "$1" = "status" ]
then

    cd "${CHROOT_DIR}" || exit 5


    PRETTY_OUT_COLUMN=$(ls -1 | awk '{ if(length($1) > max) { max = length($1) }} END { print max }')

    # printf isn't aware of emojis, need -2 chars per emoji
    printf "%${PRETTY_OUT_COLUMN}s %15s %16s %18s %40s\n" \
    	"machine" "local version" "remote version" "state" "elapsed time since"

    printf "%${PRETTY_OUT_COLUMN}s %15s %16s %18s %40s\n" \
    	"-------" "---------" "-----------" "-------------" "-------------"

    for i in *
    do
        test -d "${i}" || continue
        RESULT=$(find "${i}/logs/" -type f -cnewer "${i}/last_change_date" | sort -n)

        # date calculation
        LASTLOG=$(find "${i}/logs/" -type f | sort -n | tail -n 1)
        LASTCONFIG=$(date -r "${i}/last_change_date" "+%s")
        ELAPSED_SINCE_LATE="new config $(elapsed_time $(( $(date +%s) - "$LASTCONFIG")))"
        EXPECTED_CONFIG="$(awk -F '=' -v host="${i}" 'host == $1 { print $2 }' states.txt | cut -b 1-8)"

        if [ -z "${EXPECTED_CONFIG}" ]; then EXPECTED_CONFIG="non-flakes" ; fi

        # skip if no logs (for new hosts)
        if     [ -z "${LASTLOG}" ]
        then
            display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "" "new machine    "  "($ELAPSED_SINCE_LATE)    "
            continue
        fi

        LASTLOGVERSION="$(echo "$LASTLOG" | awk -F '_' '{ print $2 }' | awk -F '-' '{ print $1 }' )"
        NIXPKGS_DATE="$(echo "$LASTLOG" | awk -F '_' '{ print $2 }' | awk -F '-' '{ printf("%s", $NF) }' )"
        LASTTIME=$(date -r "$LASTLOG" "+%s")
        ELAPSED_SINCE_UPDATE="build $(elapsed_time $(( $(date +%s) - "$LASTTIME" )))"


        if grep "^${i}=${LASTLOGVERSION}" states.txt >/dev/null
        then
            MATCH="💚"
            MATCH_IF=1
        else
            # we don't know the state of a non-flake
            if [ "${EXPECTED_CONFIG}" = "non-flakes" ]
            then
                MATCH="    "
            else
                MATCH="🛑"
            fi
            MATCH_IF=0
        fi

        SHORT_VERSION="$(echo "$LASTLOGVERSION" | cut -b 1-8)"

        # Too many logs while there should be only one
        if [ "$(echo "$RESULT" | awk 'END { print NR }')" -gt 1 ]
        then
            display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "${SHORT_VERSION} ${MATCH}" "extra logs 🔥" "($ELAPSED_SINCE_UPDATE) ($ELAPSED_SINCE_LATE)"
            continue
        fi

        # no result since we updated configuration files
        # the client is not up to date
        if [ -z "$RESULT" ]
        then
            if [ "${MATCH_IF}" -eq 0 ]
            then
                display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "${SHORT_VERSION} ${MATCH}" "rebuild pending 🚩" "($ELAPSED_SINCE_UPDATE) ($ELAPSED_SINCE_LATE)"
            else
                display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "${SHORT_VERSION} ${MATCH}" "sync pending 🚩" "($ELAPSED_SINCE_UPDATE) ($ELAPSED_SINCE_LATE)"
            fi
            # if no new log
            # then it can't be in another further state
            continue
        fi

        # check if latest log contains rollback
        if echo "$LASTLOG" | grep rollback >/dev/null
        then
            display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "${SHORT_VERSION} ${MATCH}" "    rollbacked ⏪" "($ELAPSED_SINCE_UPDATE)"
        fi

        # check if latest log contains success
        if echo "$LASTLOG" | grep success >/dev/null
        then
            display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "${SHORT_VERSION} ${MATCH}" "    up to date 💚" "($ELAPSED_SINCE_UPDATE)"
        fi

        # check if latest log contains failure
        if echo "$LASTLOG" | grep failure >/dev/null
        then
            display_table "$PRETTY_OUT_COLUMN" "$i" "${EXPECTED_CONFIG}" "${SHORT_VERSION} ${MATCH}" "       failing 🔥" "($ELAPSED_SINCE_UPDATE) ($ELAPSED_SINCE_LATE)"
        fi

    done
fi
