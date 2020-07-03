#!/usr/bin/env bash

failure() {
    local lineno=$1
    local msg=$2
    echo "Failed at $lineno: $msg"
}
trap 'failure ${LINENO} "$BASH_COMMAND"' ERR
set -e
set -o pipefail

# bounded increase/decrease
incr() { bc -l <<< "if (($1 + $2) <= $3) ($1 + $2) else $3" ;  }
decr() { bc -l <<< "if (($1 - $2) >= $3) ($1 - $2) else $3" ;  }

usage() {
    echo "Usage: $0 -p pid [-n] [-v] [--info] [-I interval] [-o output] [--log logfile]"
    echo "  -n      dryrun, do not actually perform the switch"
    echo "  -v      verbose, print some information every I s"
    echo "  --info  info, just print configuration info and quit"
    exit "$1"
}

ceildev() { echo "$(( ($1 + $2 - 1) / $2  ))" ;  }

info () {
    echo -n "$(my_date) : PW_c = $dtlb_c_oh % | VMM_c = $vmm_c_oh | Sum = $total_c_oh % | W_sum = $overhead | gI_PC = $gipc"
    echo " | Mode = $mode_name | L = $level"
}

# $1 / $2 * $3 (default $3 = 1)
function div_mul () { bc -l <<< "scale=2;${3:-1}*$1/$2"; }

function my_date () { echo "${SECONDS}s"; }

function current_mode () { cat "$pms_path" 2>/dev/null; }

function switch () {
    echo "$i : $(my_date) SWITCH to $1"
    echo "$1" > "$pms_path"
    echo "$i : $(my_date) SWITCH DONE"
}

perflog="/dev/null"
info="false"
dryrun="false" # = don't switch, just report
verbose="false"
W_1="1"
W_2="1"
# default = sum

# configuration
source rpms.config
if [[ -n $GLOBAL_H_T ]]; then
    SHADOW_EPT_THR="$GLOBAL_H_T"
    EPT_SHADOW_THR="$GLOBAL_H_T"
fi

if [[ -n $GLOBAL_L_T ]]; then
    L_THR=$GLOBAL_L_T
fi

l_threshold=$L_THR

time_diff="$DEFAULT_I"
while [[ $# -gt 0 ]]; do
    case $1 in
        --info)
            info="true"; shift ;;
        -p)
            qemu_pid="$2"; shift 2;;
        -o)
            output="$2"; shift 2 ;;
        -I)
            time_diff="$2"; shift 2 ;;
        -v)
            verbose="true"; shift ;;
        -n)
            dryrun="true"; shift ;;
        --log)
            perflog="$2"; shift 2 ;;
        -h|--help)
            usage 0 ;;
        *)
            usage 1 ;;
    esac
done

[[ "$info" == "true" ]] ||  [[ -n $qemu_pid ]] || usage 1
rounds_to_skip=$(ceildev "$SKIP_TIME" "$time_diff")

if [[ $info == "true" ]]; then
    echo -n "RPMS : SHADOW_EPT_THR = $SHADOW_EPT_THR | EPT_SHADOW_THR = $EPT_SHADOW_THR | L_THR = $L_THR | I = $time_diff"
    echo " | Skip $rounds_to_skip rounds after switch | W1,2 = $W_1,$W_2 | FSM_n = $STATE_N | DYNAMIC THRs = $DYNAMIC"
    exit 0
fi


# debugfs PM switch path
pms_path=$(echo /sys/kernel/debug/kvm/"$qemu_pid"*/pms |tail -n1)

# NAME:perf selector
events=""
events+=" cpuload:task-clock"
events+=" total_c:cycles:HG"
events+=" g_instr:instructions:G"
#events+=" host_uc:cycles:Hu"
events+=" vmm_c:r003c:Hk"
#events+=" pfs:kvm:kvm_page_fault" #events+=" vmexits:kvm:kvm_exit"
events+=" dtlb_l_c:cpu/event=0x08,umask=0x10,cmask=0x01/G"
events+=" dtlb_s_c:cpu/event=0x49,umask=0x10,cmask=0x01/G"
#events+=" dtlb_l_wc:r0e08" # dtlb_load_misses.walk_completed #events+=" dtlb_s_wc:r0e49" # dtlb_store_misses.walk_completed

perf_events=""
metrics=""
for event in $events; do
    perf_events+=" -e ${event#*:}"
    metrics+=" ${event%%:*}"
done

perf_monitor_option="-t $( "$QEMU_VCPUS" | paste -sd ",")"
skip=0
i=0
mode=$(cat "$pms_path" 2>/dev/null)
level=0
max_level=$STATE_N

if [[ -n $output ]]; then
    exec > "$output"
fi

[[ $mode -eq 0 ]] && start_mode="shadow"
[[ $mode -eq 1 ]] && start_mode="ept"

SECONDS=0
[[ "$dryrun" == "false" ]] && sleep "$INIT_WAIT_s"

echo "$(my_date) :  START , $start_mode"

while kill -0 "$qemu_pid" &> /dev/null ; do

    for metric in $metrics; do
        #skip lines with '#'
        while read -ra line && [[ ${line[0]} == "#" ]]; do :; done
        if [[ $metric == "cpuload" ]]; then
            value="${line[5]//,/}"
        else
            value="${line[1]//,/}"
        fi

        #continue @outer loop if not integer
        [[ ! $value == [0-9]* ]] && continue 2

        declare "$metric"="$value"
    done

    # check mode update has finished
    [[ $mode != $(current_mode) ]] && continue

    cpig=$(div_mul $total_c $g_instr)
    gipc=$(bc -l <<< "scale=2; 1 / $cpig ")

    dtlb_c_oh=$(div_mul $((dtlb_l_c + dtlb_s_c)) $total_c 100)

    vmm_c_oh=$(div_mul $vmm_c $total_c 100)

    total_c_oh=$(bc -l <<< "$vmm_c_oh + $dtlb_c_oh")

    # skip some rounds after each switch
    # adjust threshold if right after switch gipc was impacted
    if [[ $skip -gt 0 ]]; then
        ((skip--)) || :
        # configurable whether thresholds are dynamic or not
        if "$DYNAMIC" && [[ $skip -eq 0 ]]; then
            change=""
            # How much to punish/reward thresholds ?

            if [[  $( bc -l <<< "$gipc < 0.9*$old_gipc") -eq 1  ]]; then
                echo -n "Bad change, gipc : $old_gipc -> $gipc, "
                change="incr"
                dt=$(bc -l <<< "scale=2; 2 * $old_gipc / $gipc") # no -l for integer division
                limit="100" # no limit
            elif [[  $( bc -l <<< "$gipc > 1.1*$old_gipc") -eq 1  ]]; then
                echo -n "Good change, gipc : $old_gipc -> $gipc, "
                change="decr"
                dt=$(bc -l <<< "scale=2; 2 * $gipc / $old_gipc")
                limit="$L_THR"
            fi

            if [[ -n $change ]]; then
                # if current mode is shadow then change ept->shadow threshold accordingly
                [[ $mode -eq 0 ]] && EPT_SHADOW_THR=$("$change" $EPT_SHADOW_THR $dt $limit)
                # same for ept
                [[ $mode -eq 1 ]] && SHADOW_EPT_THR=$("$change" $SHADOW_EPT_THR $dt $limit)
                echo "HT_ept->shadow = $EPT_SHADOW_THR, HT_shadow->ept = $SHADOW_EPT_THR"
            fi
        fi
        continue
    fi

    # low cpuload, don't bother
    [[ $(bc -l <<< "$cpuload < 0.60") -eq 1 ]] && continue

    old_gipc="$gipc"

    if [[ $mode -eq 0 ]]; then
        # SHADOW
        mode_name='SHADOW'
        m='VMM'
        overhead=$(bc -l <<< "$W_1*$vmm_c_oh + $W_2*$dtlb_c_oh") #$vmm_c_oh
        h_threshold=$SHADOW_EPT_THR
        dl=1
        target_mode=1
        target_level=$max_level
    else
        # EPT
        mode_name='EPT'
        m='PW'
        overhead=$(bc -l <<< "$W_1*$dtlb_c_oh + $W_2*$vmm_c_oh") #$dtlb_c_oh
        h_threshold=$EPT_SHADOW_THR
        dl=-1
        target_mode=0
        target_level="$(bc -l <<< "-$max_level")"
    fi


    level_changed="true"
    if [[ $(bc -l <<< "$overhead > $h_threshold") -eq 1 ]]; then
        #dl=$(bc <<< "$dl * ( $overhead / $h_threshold )")
        (( level += dl )) || :
    elif [[ $(bc -l <<< "$overhead < $l_threshold") -eq 1 ]]; then
        #dl=$(bc <<< "$dl * ( $l_threshold / $overhead )")
        (( level -= dl )) || :
    else
        level_changed="false"
    fi

    [[ $level -gt $max_level ]] && level=$max_level
    [[ $level -lt -$max_level ]] && level="$(bc -l <<< "-$max_level")"
    [[ "$level" == "-0" ]] && level=0

    [[ ( "$level_changed" == "true" ) || ("$verbose" == "true") ]] && info

    [[ "$level_changed" == "false" ]] && continue

    [[ "$dryrun" == "true" ]] && continue

    if [[ ( $level -eq $target_level ) && ( "$target_mode" != "$mode" ) ]]; then
        (( mode = 1 - "$mode" )) || :
        (( ++i ))
        skip=$rounds_to_skip
        switch "$mode" &
    fi
    continue

done < <(perf kvm stat $perf_events -I $time_diff $perf_monitor_option 2>&1 | tee -a $perflog)

echo "$(my_date) : END , mode $mode"
