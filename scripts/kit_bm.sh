#!/bin/bash

### Setting
enable_perf=0

### Constantis
username="kit"

host_ip="192.168.1.120"
server_node_list="machine_list.txt"
worker_node_list="machine_list.txt"
model_path="/home/${username}/exp/script/dnn"
run_path="/home/${username}/run/dnn"
python_path="/home/${username}/anaconda2"
data_path="/home/${username}/exp/data"

ps_port=8700
worker_port=8800
process_name='python'

server_script_head+="echo '#!/bin/bash' > ${run_path}/s.sh; chmod +x ${run_path}/s.sh; echo cd ${run_path} >> ${run_path}/s.sh;"
worker_script_head+="echo '#!/bin/bash' > ${run_path}/w.sh; chmod +x ${run_path}/w.sh; echo cd ${run_path} >> ${run_path}/w.sh;"

### Utils
function remote_cmd()
{
    ssh -n -l ${username} ${1} "${2}"
}


function remote_bg_cmd()
{
    ssh -n -f -l ${username} ${1} "{ ${2} } >/dev/null 2>&1 &"
}


function remote_cmds()
{
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "Execute command " "$*" " in " ${line}
            remote_cmd ${line} $*
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function count_machine()
{
    local total=0
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            (( total += 1 ))
        fi
    done < ${1}
    echo ${total}
}
 


### UDFs
function install_python()
{
    rm -rf ${python_path}
    echo copying from source
    scp -r -q -C ${username}@10.172.140.102:${python_path} ${python_path}

    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ] && [ "${line}" != ${host_ip} ] 
        then
            echo copying python to ${line}
            scp -r -q -C ${python_path} ${username}@${line}:${python_path}
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function copy_tensorflow()
{
    local lib_path="${python_path}/lib/python2.7/site-packages/"
    rm -rf ${lib_path}/tensor*

    echo copying from source
    scp -r -q -C ${username}@10.172.140.102:${lib_path}/tensor* ${lib_path}/

    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ] && [ "${line}" != ${host_ip} ] 
        then
            echo copying python to ${line}
            remote_cmd ${line} "rm -rf ${lib_path}/tensor*"
            scp -r -q -C ${lib_path}/tensor* ${username}@${line}:${lib_path}
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function gen_script()
{
    local index=0
    local ps_list=""

    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            if [ ${index} -gt 0 ]; then
                ps_list+=','
            fi
            ps_list+="${line}:${ps_port}"
            (( index += 1 ))
        fi
    done < ${server_node_list}
 
    local worker_list=""    
    index=0
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            if [ ${index} -gt 0 ]; then
                worker_list+=','
            fi
            worker_list+="${line}:${worker_port}"
            (( index += 1 ))
        fi
    done < ${worker_node_list}

    index=0
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "Generating server script to " ${line}
            local server_cmd=${server_script_head}
            if [ ${enable_perf} -eq 1 ]
            then
                server_cmd+="echo \"perf record -q -g -o server.perf python -u kit_benchmark.py --ps_hosts=${ps_list} --worker_hosts=${worker_list} --job_name=ps --task_index=${index} \" >> ${run_path}/s.sh"
            else
                server_cmd+="echo \"CUDA_VISIABLE_DEVICE="" python -u send_recv_benchmark.py --ps_hosts=${ps_list} --worker_hosts=${worker_list} --job_name=ps --task_index=${index} 2>&1 | tee s.result.txt \" >> ${run_path}/s.sh"
            fi
            remote_cmd ${line} "${server_cmd}"
            (( index += 1 ))
        fi
    done < ${server_node_list}
    
    index=0
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "Generating worker script to " ${line}
            local worker_cmd=${worker_script_head}
            if [ ${enable_perf} -eq 1 ]
            then
                worker_cmd+="echo \"perf record -q -g -o worker.perf python -u kit_benchmark.py --ps_hosts=${ps_list} --worker_hosts=${worker_list} --job_name=worker --task_index=${index} $*\" >> ${run_path}/w.sh"
            else
                worker_cmd+="echo \"CUDA_VISIABLE_DEVICE="" python -u send_recv_benchmark.py --ps_hosts=${ps_list} --worker_hosts=${worker_list} --job_name=worker --task_index=${index} $* 2>&1 | tee w.result.txt  \" >> ${run_path}/w.sh"
            fi
            remote_cmd ${line} "${worker_cmd}"
            (( index += 1 ))
        fi
    done < ${worker_node_list}
}


function start_server()
{
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "Start server process ${line}"
            remote_bg_cmd ${line} "${run_path}/s.sh &"
        fi
    done < ${server_node_list}    
}


function start_worker()
{
    local mc=$( count_machine ${worker_node_list} )
    local index=0
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            (( index += 1))
            echo "Start worker process ${line}"
            if [ ${index} -lt ${mc} ]
            then
                remote_bg_cmd ${line} "${run_path}/w.sh &"
            else
                remote_cmd ${line} "${run_path}/w.sh"
                #echo abc
            fi
        fi
    done < ${worker_node_list}
    
}


function perf_server()
{
    echo nothing
}


function perf_worker()
{
    ps aux | grep "python" | grep "=worker" | awk '{print $2}' | xargs -i perf record -o "worker.perf" -p {}
}



### Functions
function kill_process()
{
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ] 
        then
            echo "Killing process" ${line}
            remote_cmd ${line} "pkill -9 -u ${username} -f ${process_name}"
            remote_cmd ${line} "rm -f ${run_path}/*.result.txt"
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function print_process()
{
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ] 
        then
            echo "Print process" ${line}
            remote_cmd ${line} "ps aux | grep ${process_name}"
            echo ""
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function get_log()
{
    local idx=${1}
    
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            if [ ${idx} -eq 0 ]
            then
                remote_cmd ${line} "cat ${run_path}/s.result.txt"
            fi
            (( idx -= 1))
        fi
    done < ${server_node_list}

    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            if [ ${idx} -eq 0 ]
            then
                echo "Print log from" ${line}
                remote_cmd ${line} "cat ${run_path}/w.result.txt"
            fi
            (( idx -= 1))
        fi
    done < ${worker_node_list} 
}


function setup () 
{
    kill_process
#    install_python
    copy_tensorflow
}


function auth()
{
    if [ ! -f "/home/${username}/.ssh/id_rsa.pub" ]; then
        ssh-keygen -t rsa
    fi

    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "copying authority to ${line}"
            ssh-copy-id -i /home/${username}/.ssh/id_rsa.pub "${line}"
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function copy_model()
{
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "copying scripts to ${line}"
            remote_cmd ${line} "mkdir -p ${run_path}"
            scp -r -q -C ${model_path}/* ${username}@${line}:${run_path}
        fi
    done < <(sort ${server_node_list} ${worker_node_list} | uniq)
}


function copy_data()
{
    while IFS= read -r line; do
        if [ "${line:0:1}" != "#" ]
        then
            echo "copying data to ${line}"
            remote_cmd ${line} "mkdir -p ${run_path}/data"
            scp -r -C ${data_path}/* ${username}@${line}:${run_path}/data
       fi
    done < ${worker_node_list} 
}


function startall()
{
    kill_process
    start_server
    start_worker
}


function usage ()
{
    echo "Call Usage"
}



############################
# main ()                  #

case "${1}" in
    "auth") auth
    ;;

    "setup" | "st") setup
    ;;

    "remote_cmd" | "rc")
        shift
        remote_cmds $*
    ;;

    "genscript" | "gs") 
        shift
        gen_script $*
    ;;

    "copymodel" | "cm") copy_model
    ;;

    "copydata" | "cd") copy_data
    ;;

    "startall" | "sa") startall
    ;;

    "startserver" | "ss") start_server
    ;;

    "perfserver") perf_server
    ;;

    "startworker" | "sw") start_worker
    ;;

    "perfworker" | "pw") perf_worker
    ;;

    "kill" | "k") kill_process
    ;;

    "ps") print_process
    ;;

    "log") get_log ${2}
    ;;

    "help" | "h" | "") usage
    ;;

    *) echo "Invalid command ${1}!"
    ;;

esac
