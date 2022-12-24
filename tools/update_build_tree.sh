#! /bin/bash

# Copyright (C) 2022 Charles Michael Atkinson
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA

# Purpose: 
#   * Sets file permissions
#   * Updates debian/changelog and debian/copyright for the requested package version, example 3.2.2-1
#   * Removes any source/wireguard-git_<version>.orig.tar.gz for an earlier version
#   * Creates a tag with the requested package version's name

# Usage:
#   See usage.fun or use -h option

# Programmers' notes: function call tree
#    +
#    |
#    +-- initialise
#    |   |
#    |   +-- usage
#    |
#    +-- set_perms
#    |
#    +-- update
#    |
#    +-- commit
#    |
#    +-- tag
#    |
#    +-- finalise
#
# Utility functions called from various places:
#    ck_file fct msg

# Function definitions in alphabetical order.  Execution begins after the last function definition.

#--------------------------
# Name: ck_file
# Purpose: for each file listed in the argument list: checks that it is 
#   * reachable and exists
#   * is of the type specified (block special, ordinary file or directory)
#   * has the requested permission(s) for the user
#   * optionally, is absolute (begins with /)
# Usage: ck_file [ path <file_type>:<permissions>[:[a]] ] ...
#   where 
#     file  is a file name (path)
#     file_type  is b (block special file), f (file) or d (directory)
#     permissions  is none or more of r, w and x
#     a  requests an absoluteness test (that the path begins with /)
#   Example:
#     buf=$(ck_file foo f:rw 2>&1)
#     if [[ $buf != '' ]]; then
#          msg W "$buf"
#          fct "${FUNCNAME[0]}" 'returning 1'
#          return 1
#     fi
# Outputs:
#   * For the first requested property each file does not have, a message to
#     stderr
#   * For the first detected programminng error, a message to
#     stderr
# Returns: 
#   0 when all files have the requested properties
#   1 when at least one of the files have the requested properties
#   2 when a programming error is detected
#--------------------------
function ck_file {

    local absolute_flag buf file_name file_type perm perms retval

    # For each file ...
    # ~~~~~~~~~~~~~~~~~
    retval=0
    while [[ $# -gt 0 ]]
    do  
        file_name=$1
        file_type=${2%%:*}
        buf=${2#$file_type:}
        perms=${buf%%:*}
        absolute=${buf#$perms:}
        [[ $absolute = $buf ]] && absolute=
        case $absolute in 
            '' | a )
                ;;
            * )
                echo "ck_file: invalid absoluteness flag in '$2' specified for file '$file_name'" >&2
                return 2
        esac
        shift 2

        # Is the file reachable and does it exist?
        # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        case $file_type in
            b ) 
                if [[ ! -b $file_name ]]; then
                    echo "file '$file_name' is unreachable, does not exist or is not a block special file" >&2
                    retval=1
                    continue
                fi  
                ;;  
            f ) 
                if [[ ! -f $file_name ]]; then
                    echo "file '$file_name' is unreachable, does not exist or is not an ordinary file" >&2
                    retval=1
                    continue
                fi  
                ;;  
            d ) 
                if [[ ! -d $file_name ]]; then
                    echo "directory '$file_name' is unreachable, does not exist or is not a directory" >&2
                    retval=1
                    continue
                fi
                ;;
            * )
                echo "Programming error: ck_file: invalid file type '$file_type' specified for file '$file_name'" >&2
                return 2
        esac

        # Does the file have the requested permissions?
        # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        buf="$perms"
        while [[ $buf ]]
        do
            perm="${buf:0:1}"
            buf="${buf:1}"
            case $perm in
                r )
                    if [[ ! -r $file_name ]]; then
                        echo "$file_name: no read permission" >&2
                        retval=1
                        continue
                    fi
                    ;;
                w )
                    if [[ ! -w $file_name ]]; then
                        echo "$file_name: no write permission" >&2
                        retval=1
                        continue
                    fi
                    ;;
                x )
                    if [[ ! -x $file_name ]]; then
                        echo "$file_name: no execute permission" >&2
                        retval=1
                        continue
                    fi
                    ;;
                * )
                    echo "Programming error: ck_file: invalid permisssion '$perm' requested for file '$file_name'" >&2
                    return 2
            esac
        done

        # Does the file have the requested absoluteness?
        # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        if [[ $absolute = a && ${file_name:0:1} != / ]]; then
            echo "$file_name: does not begin with /" >&2
            retval=1
        fi

    done

    return $retval

}  #  end of function ck_file

#--------------------------
# Name: ck_uint
# Purpose: checks for a valid unsigned integer
# Usage: ck_uint <putative uint>
# Outputs: none
# Returns: 
#   0 when $1 is a valid unsigned integer
#   1 otherwise
#--------------------------
function ck_uint {
    local regex='^[[:digit:]]+$'
    [[ $1 =~ $regex ]] && return 0 || return 1
}  #  end of function ck_uint

#--------------------------
# Name: commit
# Purpose: commits any changes made by the update function
#--------------------------
function commit {
    fct "${FUNCNAME[0]}" 'started'
    local buf cmd rc msg
    local changes_to_commit git_status_out n_changes_to_commit n_merge_conflicts

    # Anything to commit?
    # ~~~~~~~~~~~~~~~~~~~
    cmd=(git status --untracked-files=no --porcelain)
    git_status_out=$("${cmd[@]}" 2>&1)
    rc=$?
    if ((rc!=0)); then
        msg=$'\n'"Command: ${cmd[*]}"
        msg+=$'\n'"rc: $rc"
        msg+=$'\n'"Output: $git_status_out"
        msg E "$msg"
    fi
    changes_to_commit=$(echo "$git_status_out" | grep '^ M')
    n_changes_to_commit=$(echo "$changes_to_commit" | wc -l)
    if ((n_changes_to_commit==0)); then
        committed_flag=$false
        msg I 'No changes to commit'
        fct "${FUNCNAME[0]}" 'returning'
        return 0
    fi

    # Any merge conflicts?
    # ~~~~~~~~~~~~~~~~~~~~
    n_merge_conflicts=$(echo "$git_status_out" | grep '^U' | wc -l)
    if ((n_merge_conflicts!=0)); then
        msg E "Merge conflicts"$'\n'"$git_status_out"
    fi

    # Commit
    # ~~~~~~
    msg I "Committing changes"$'\n'"$changes_to_commit"
    cmd=(git commit --all --message "$new_pack_full_ver")
    buf=$("${cmd[@]}" 2>&1)
    rc=$?
    if ((rc!=0)) ; then
        msg=$'\n'"Command: ${cmd[*]}"
        msg+=$'\n'"rc: $rc"
        msg+=$'\n'"Output: $buf"
        msg E "$msg"
    fi
    committed_flag=$true

    fct "${FUNCNAME[0]}" 'returning'
}  # end of function commit

#--------------------------
# Name: fct
# Purpose: function call trace (for debugging)
# $1 - name of calling function 
# $2 - message.  If it starts with "started" or "returning" then the output is prettily indented
#--------------------------
function fct {

    if [[ ! $debugging_flag ]]; then
        return 0
    fi

    fct_indent="${fct_indent:=}"

    case $2 in
        'started'* )
            fct_indent="$fct_indent  "
            msg D "$fct_indent$1: $2"
            ;;
        'returning'* )
            msg D "$fct_indent$1: $2"
            fct_indent="${fct_indent#  }"
            ;;
        * )
            msg D "$fct_indent$1: $2"
    esac
}  # end of function fct

#--------------------------
# Name: finalise
# Purpose: cleans up and exits
# Arguments:
#    $1  exit code
# Exit code: 
#   When not terminated by a signal, the sum of zero plus
#      1 when any warnings
#      2 when any errors
#   When terminated by a trapped signal, the sum of 128 plus the signal number
#--------------------------
function finalise {
    fct "${FUNCNAME[0]}" "started with args $*" 
    local my_exit_code sig_name

    finalising_flag=$true

    # Interrupted?
    # ~~~~~~~~~~~~
    my_exit_code=0
    if ck_uint "${1:-}"; then
        if (($1>128)); then    # Trapped interrupt
            interrupt_flag=$true
            i=$((128+${#sig_names[*]}))    # Max valid interrupt code
            if (($1<i)); then
                my_exit_code=$1
                sig_name=${sig_names[$1-128]}
                msg I "Finalising on $sig_name" 
                [[ ${summary_fn:-} != '' ]] \
                    && echo "Finalising on $sig_name" >> "$summary_fn" 
            else
               msg="${FUNCNAME[0]} called with invalid exit value '${1:-}'" 
               msg+=" (> max valid interrupt code $i)" 
               msg E "$msg"    # Returns because finalising_flag is set
            fi
        fi
    fi

    # Exit code value adjustment
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~
    if [[ ! $interrupt_flag ]]; then
        if [[ $warning_flag ]]; then
            msg I "There was at least one WARNING" 
            ((my_exit_code+=1))
        fi
        if [[ $error_flag ]]; then
            msg I "There was at least one ERROR" 
            ((my_exit_code+=2))
        fi
        if ((my_exit_code==0)) && ((${1:-0}!=0)); then
            my_exit_code=2
        fi
    else
        msg I "There was a $sig_name interrupt" 
    fi

    # Remove PID file
    # ~~~~~~~~~~~~~~~
    [[ $pid_file_locked_flag ]] && rm "$pid_fn" 

    # Exit
    # ~~~~
    fct "${FUNCNAME[0]}" 'exiting'
    exit $my_exit_code
}  # end of function finalise

#--------------------------
# Name: initialise
# Purpose: sets up environment, parses command line, reads config file
#--------------------------
function initialise {
    local args buf emsg opt opt_v_flag

    # Configure shell environment
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~
    buf=$(locale --all-locales | grep 'en_.*utf8')
    if [[ $buf = '' ]]; then
        echo 'ERROR: locale --all-locales did not list any English UTF8 locales' >&2
        exit 1
    fi
    export LANG=$(echo "$buf" | head -1)
    export LANGUAGE=$LANG
    for var_name in LC_ADDRESS LC_ALL LC_COLLATE LC_CTYPE LC_IDENTIFICATION \
        LC_MEASUREMENT LC_MESSAGES LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER \
        LC_TELEPHONE LC_TIME 
    do
        unset $var_name
    done

    export PATH=/usr/sbin:/sbin:/usr/bin:/bin
    IFS=$' \n\t'
    set -o nounset
    shopt -s extglob            # Enable extended pattern matching operators
    unset CDPATH                # Ensure cd behaves as expected
    umask 022

    # Initialise some global logic variables
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    readonly false=
    readonly true=true

    debugging_flag=$false
    error_flag=$false
    finalising_flag=$false
    interrupt_flag=$false
    logging_flag=$false
    pid_file_locked_flag=$false
    warning_flag=$false

    # Set global read-only non-logic variables
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    declare -gr msg_lf=$'\n    '
    declare -gr my_pid=$$
    declare -gr pid_dir=/tmp
    declare -gr my_name=${0##*/}
    declare -gr sig_names=(. $(kill -L | sed 's/[[:digit:]]*)//g'))
    declare -gr valid_package_ver_re='^[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+-[[:digit:]]+$'

    # Initialise some global non-logic variables
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # None wanted

    # Parse command line
    # ~~~~~~~~~~~~~~~~~~
    args=("$@")
    args_org="$*" 
    emsg=
    opt_v_flag=$false
    while getopts :dhv: opt "$@" 
    do
        case $opt in
            d )
                debugging_flag=$true
                ;;
            h )
                debugging_flag=$false
                usage verbose
                exit 0
                ;;
            v )
                opt_v_flag=$true
                new_pack_full_ver=$OPTARG
                ;;
            : )
                emsg+=$msg_lf"Option $OPTARG must have an argument" 
                ;;
            * )
                emsg+=$msg_lf"Invalid option '-$OPTARG'" 
        esac
    done

    # Check for mandatory options missing
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    [[ ! $opt_v_flag ]] && emsg+=$msg_lf"Option -v is required"

    # Test for mutually exclusive options
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # There are no mutually exclusive options

    # Validate option values
    # ~~~~~~~~~~~~~~~~~~~~~~
    if [[ ${new_pack_full_ver:-} != '' ]] \
        && [[ ! $new_pack_full_ver =~ $valid_package_ver_re ]]; then
        emsg+=$msg_lf"Invalid package version $new_pack_full_ver (not n.n.n-n)"
    fi

    # Test for extra arguments
    # ~~~~~~~~~~~~~~~~~~~~~~~~
    shift $(($OPTIND-1))
    if [[ $* != '' ]]; then
        emsg+=$msg_lf"Invalid extra argument(s) '$*'" 
    fi

    # Report any command line errors
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    if [[ $emsg != '' ]]; then
        emsg+=$msg_lf'(-h for help)'
        msg E "Command line error(s)$emsg" 
    fi

    # Check the PID directory
    # ~~~~~~~~~~~~~~~~~~~~~~~
    mkdir -p "$pid_dir" 2>/dev/null
    buf=$(ck_file "$pid_dir" d:rwx: 2>&1)
    [[ $buf != '' ]] && msg E "$buf" 

    # Report any errors
    # ~~~~~~~~~~~~~~~~~
    if [[ $emsg != '' ]]; then
        msg E "$emsg" 
    fi

    # Set traps
    # ~~~~~~~~~
    for ((i=1;i<${#sig_names[*]};i++))
    do   
        ((i==9)) && continue     # SIGKILL
        ((i==17)) && continue    # SIGCHLD
        trap "finalise $((128+i))" ${sig_names[i]#SIG}
    done

    # Ensure in the root of the git working tree
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    [[ ! -d .git ]] && msg E "$my_name must be run in the root of the git working tree"
    
    # Derive versions
    # ~~~~~~~~~~~~~~~
    new_software_ver=${new_pack_full_ver%-*}
    new_pack_ver=${new_pack_full_ver##*-}

    fct "${FUNCNAME[0]}" 'returning'
}  # end of function initialise

#--------------------------
# Name: msg
# Purpose: generalised messaging interface
# Arguments:
#    $1 class: D, E, I or W indicating Debug, Error, Information or Warning
#    $2 message text
# Global variables read:
#     my_name
# Output: information messages to stdout; the rest to stderr
# Returns: 
#   Does not return (calls finalise) when class is E for error
#   Otherwise returns 0
#--------------------------
function msg {
    local buf class logger_msg message_text prefix priority

    # Process arguments
    # ~~~~~~~~~~~~~~~~~
    class="${1:-}"
    message_text="${2:-}"

    # Class-dependent set-up
    # ~~~~~~~~~~~~~~~~~~~~~~
    case "$class" in
        D )
            [[ ! $debugging_flag ]] && return
            prefix='DEBUG: '
            priority=
            ;;
        E )
            error_flag=$true
            prefix='ERROR: '
            priority=err
            ;;
        I )
            prefix=
            priority=info
            ;;
        W )
            warning_flag=$true
            prefix='WARN: '
            priority=warning
            ;;
        * )
            msg E "msg: invalid class '$class': '$*'"
    esac

    # Write to stdout or stderr
    # ~~~~~~~~~~~~~~~~~~~~~~~~~
    message_text="$prefix$message_text"
    if [[ $class = I ]]; then
        echo "$message_text"
    else
        echo "$message_text" >&2
        if [[ $class = E ]]; then
            [[ ! $finalising_flag ]] && finalise 1
        fi
    fi

    return 0
}  #  end of function msg

#--------------------------
# Name: set_perms
# Purpose: sets file permissions
#--------------------------
function set_perms {
    fct "${FUNCNAME[0]}" 'started'
    local executables list

    msg I 'Setting 644 permissions on all files except under .git'
    find -path ./.git -prune -o -type f -exec chmod 644 {} + || finalise 1

    executables=($(echo .git/hooks/{post-checkout,post-merge,pre-commit}))
    executables+=($(echo debian/{mk_htm_and_pdf_from_odts.sh,postinst,postrm,prerm,rules}))
    executables+=($(echo tools/{build_deb.sh,update_build_tree.sh}))
    executables+=($(echo tools/git-store-meta/git-store-meta.pl))
    executables+=($(echo tools/git-store-meta/hooks-for-wireguard-kit/{post-checkout,post-merge,pre-commit}))
    for fn in "${executables[@]}"
    do
        list+=$'\n'"$fn"
    done
    msg I "Setting 755 permissions on $list"
    chmod 755 "${executables[@]}" || finalise 1

    fct "${FUNCNAME[0]}" 'returning'
}  # end of function set_perms

#--------------------------
# Name: tag
# Purpose: creates a git tag named after the package version
#--------------------------
function tag {
    fct "${FUNCNAME[0]}" 'started'
    local buf cmd rc msg
    local -r tag_delete_ouput_ok_re='^Deleted tag '

    msg I "Creating annotated git tag $new_pack_full_ver"
    # --force is used to replace any existing tag with the same name
    cmd=(git tag --annotate --force --message "$new_pack_full_ver" "$new_pack_full_ver")
    buf=$("${cmd[@]}" 2>&1)
    rc=$?
    if ((rc!=0)); then
        msg=$'\n'"Command: ${cmd[*]}"
        msg+=$'\n'"rc: $rc"
        msg+=$'\n'"Output: $buf"
        msg E "$msg"
    fi

    fct "${FUNCNAME[0]}" 'returning'
}  # end of function tag

#--------------------------
# Name: update
# Purpose: updates the working tree for the new package
#--------------------------
function update {
    fct "${FUNCNAME[0]}" 'started'
    local buf cmd rc msg
    local fn this_year timestamp

    # debian/changelog
    # ~~~~~~~~~~~~~~~~
    fn=debian/changelog
    timestamp=$(date '+%a, %d %b %Y %X %z')
    msg I "Ensuring package version $new_pack_full_ver and current date in $fn"
    sed --regexp-extended --in-place \
        -e "s/^wireguard-git \([^)]+\)/wireguard-git \($new_pack_full_ver\)/" \
        -e "s/[[:alpha:]]{3}, [[:digit:]]+ [[:alpha:]]{3} [[:digit:]]{4} [[:digit:]:]+ [-+][[:digit:]]{4}/$timestamp/" \
        $fn

    # debian/compat and control
    # ~~~~~~~~~~~~~~~~~~~~~~~~~
    # Cannot be automatically updated

    # debian/copyright
    # ~~~~~~~~~~~~~~~~
    fn=debian/copyright
    this_year=$(date '+%Y')
    msg I "Ensuring current year in $fn"
    sed --regexp-extended --in-place \
        "s/^(Copyright: [[:digit:]]{4}-)[[:digit:]]{4}/\1$this_year/" \
        $fn

    # debian/match
    # ~~~~~~~~~~~~
    # Does not need dupdating

    # debian/debhelper-build-stamp, install, postinst, postrm and rules
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # Cannot be automatically updated

    # debian/.debhelper/generated/wireguard-git/installed-by-dh_install
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # Cannot be automatically updated

    # debian/source/format, include-binaries, local-options and options
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # Cannot be automatically updated

    # source/wireguard-git_<version>.orig.tar.gz
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    for fn in $(echo source/wireguard-git_*.orig.tar.gz)
    do
        [[ $fn = 'source/wireguard-git_*.orig.tar.gz' ]] && break
        [[ $fn = source/wireguard-git_$new_wireguard-git_ver.orig.tar.gz ]] && continue
        msg I "Removing $fn from tree and git"
        git rm $fn || finalise 1
        rm -f $fn || finalise 1
    done

    fct "${FUNCNAME[0]}" 'returning'
}  # end of function update

#--------------------------
# Name: usage
# Purpose: prints usage message
#--------------------------
function usage {
    fct "${FUNCNAME[0]}" 'started'
    local msg usage

    # Build the messages
    # ~~~~~~~~~~~~~~~~~~
    usage="usage: $my_name " 
    msg='  where:'
    usage+='[-d] [-h] -v <package version>'
    msg+=$'\n    -d debugging on'
    msg+=$'\n    -h prints this help and exits'
    msg+=$'\n    -v the package version to set up for.  Example 3.2.2-1'

    # Display the message(s)
    # ~~~~~~~~~~~~~~~~~~~~~~
    echo "$usage" >&2
    if [[ ${1:-} != 'verbose' ]]; then
        echo "(use -h for help)" >&2
    else
        echo "$msg" >&2
    fi

    fct "${FUNCNAME[0]}" 'returning'
}  # end of function usage

#--------------------------
# Name: main
# Purpose: where it all happens
#--------------------------
initialise "${@:-}" 
set_perms
update
commit
[[ $committed_flag ]] && tag
finalise 0
