#!/bin/bash

#the full directory name of the script no matter where it is being called from
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MAIN_TOPIC="bturntable"
SPKR_TOPIC="bturntable/speaker"
AUDIO_TOPIC="bturntable/audio"

MAIN_CMD_PIPE="/tmp/main_pipe"
SPKR_CMD_PIPE="/tmp/spk_pipe"
AUDIO_CMD_PIPE="/tmp/audio_pipe"

trap "rm -f $MAIN_CMD_PIPE" exit
trap "rm -f $SPKR_CMD_PIPE" exit
trap "rm -f $AUDIO_CMD_PIPE" exit

if [[ ! -p $MAIN_CMD_PIPE ]]; then
  mkfifo $MAIN_CMD_PIPE
fi

if [[ ! -p $SPKR_CMD_PIPE ]]; then
  mkfifo $SPKR_CMD_PIPE
fi

if [[ ! -p $AUDIO_CMD_PIPE ]]; then
  mkfifo $AUDIO_CMD_PIPE
fi

sleep 1


CONF_DIR="$HOME/.bturntable"
SPKR_CONF_FILE="$CONF_DIR/speaker.conf"
HOST_BDADDR=$(hciconfig dev | grep -o "[[:xdigit:]:]\{11,17\}")


#audio params
REC_DEV="plughw:1,0"
SR=44100
BUF_SZ=2048
BR=16
EFFECTS="noisered $CONF_DIR/noise.prof 0.30 : riaa :  bass +10 : treble 5"
VERBOSE="-V1 -q"

if [ -d "$CONF_DIR" ]; then
  mkdir -p "$CONF_DIR"
fi


# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
function ctrl_c() {
   echo "Terminating..."
   killall play &> /dev/null
   killall rec  &> /dev/null
   killall mosquitto_sub &> /dev/null
   killall main_service &> /dev/null
   killall audio_service &> /dev/null
   killall speaker_service &> /dev/null
   exit
}

function service_send_cmd() {
  export srv="$1"
  export cmd="$2"
  export val="$3"
  case "$srv" in
    "speaker"*)
      (sleep 0.4 ; mosquitto_pub -t "$SPKR_TOPIC" -m "$cmd""@""$val" ) &
      ;;
    "audio"*)
      (sleep 0.4 ; mosquitto_pub -t "$AUDIO_TOPIC" -m "$cmd""@""$val" ) &
      ;;
    "main"*)
      (sleep 0.4 ; mosquitto_pub -t "$AUDIO_TOPIC" -m "$cmd""@""$val" ) &
      ;;
  esac
   
}

#Select a paired speaker by name prefix 
function speaker_select() {
  local name_prefix="$1"
  local spkr_bdaddr=""
  local spkr_name=""

  coproc bluetoothctl
  sleep 1
  echo -e 'paired-devices\n' >&${COPROC[1]}
  sleep 1
  echo -e 'exit\n' >&${COPROC[1]}
  
  local output=$(cat <&${COPROC[0]})
  spkr_bdaddr=$(echo "$output"  | grep -i "Device.*$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
  spkr_bdaddr=$(echo "$spkr_bdaddr" | awk '{$1=$1;print}' | uniq) #trim 
  spkr_name=$(echo "$output"  | grep -i "Device.*$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
  spkr_name=$(echo "$spkr_name" | awk '{$1=$1;print}' | uniq) #trim
  
  if [ "$spkr_bdaddr" != "" ];
  then
    echo "Selected speaker $spkr_name @ $spkr_bdaddr"
    echo "$spkr_bdaddr" > "$SPKR_CONF_FILE"
    echo "$spkr_name" >> "$SPKR_CONF_FILE"
  fi
}

#Pair a speaker by name prefix 
function speaker_pair() {
  name_prefix="$1"
  coproc bluetoothctl
  sleep 2
  #find spkr_bdaddr and spkr_name
  sleep 2
  echo -e 'scan on\n' >&${COPROC[1]}
  sleep 15
  echo -e 'devices\n' >&${COPROC[1]}
  sleep 1   
  echo -e 'scan off\n' >&${COPROC[1]}
  sleep 1
  echo -e 'exit\n' >&${COPROC[1]}
  local output=$(cat <&${COPROC[0]})
  local spkr_bdaddr=$(echo "$output" | grep -i "$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
  local spkr_bdaddr=$(echo "$spkr_bdaddr" | uniq)
  local spkr_name=$(echo "$output" | grep -i "$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
  local spkr_name=$(echo "$spkr_name" | awk '{$1=$1;print}' | uniq)
  coproc bluetoothctl
  sleep 2
  #pair spkr_bdaddr
  echo -e 'scan on\n' >&${COPROC[1]}
  sleep 5
  echo -e "trust $spkr_bdaddr \n" >&${COPROC[1]}
  sleep 2
  echo -e "pair $spkr_bdaddr \n" >&${COPROC[1]}
  sleep 15
  echo -e 'scan off\n' >&${COPROC[1]}
  echo -e 'paired-devices\n' >&${COPROC[1]}
  sleep 1
  echo -e 'exit\n' >&${COPROC[1]}
}


function speaker_service() 
{    
  echo "Speaker Service"
  mosquitto_sub -t "$SPKR_TOPIC" > $SPKR_CMD_PIPE & 
  local spkr_bdaddr=""
  local spkr_name=""
  local spkr_volctl=""
  local playback_dev=""
  local dbus_addr=""

  while true
  do
    if read cmd < "$SPKR_CMD_PIPE"; 
    then
      echo "Speaker Service received command : $cmd"
      case "$cmd" in     
        "load_last"*) #load last connected speaker
            if [ -f "$SPKR_CONF_FILE" ]; then
              spkr_bdaddr=$(cat "$SPKR_CONF_FILE" | head -1)
              spkr_name=$(cat "$SPKR_CONF_FILE" | tail -1)
              spkr_volctl="'$spkr_name - A2DP'"
              playback_dev="bluealsa:HCI=hci0,DEV=$spkr_bdaddr,PROFILE=a2dp"
              dbus_addr=$(echo $spkr_bdaddr | tr : _)
              echo "Loaded Speaker parameters: [$spkr_name] , [$spkr_bdaddr]"
              
              #passing variables to audio service
              service_send_cmd "audio" "playback_dev@$playback_dev"                
              service_send_cmd "audio" "spkr_volctl@$spkr_volctl"
              service_send_cmd "audio" "REC_DEV@$REC_DEV"               
              service_send_cmd "audio" "EFFECTS@$EFFECTS"              
              service_send_cmd "speaker" "connect"
            fi
            ;;
        "connect"*)
            echo "Trying to connect speaker [$spkr_name] , [$spkr_bdaddr] ..."
            local conn_status_cmd=$(dbus-send --system --reply-timeout=2000 --dest=org.bluez --print-reply /org/bluez/hci0/dev_$dbus_addr org.freedesktop.DBus.Properties.Get string:"org.bluez.Device1" string:"Connected" 2> /dev/null)
            conn_status=$(echo "$conn_status_cmd" | awk '/true|false/{print $3}')
            sleep 2
            if [ "$conn_status" == "true" ];
            then
              echo "Speaker $spkr_bdaddr connected"
              service_send_cmd "speaker" "play"
            else
              echo "Speaker not connected, retrying..."
              sleep 10
              dbus-send --system  --reply-timeout=2000 --dest=org.bluez --print-reply --type=method_call /org/bluez/hci0/dev_$dbus_addr org.bluez.Device1.Connect &> /dev/null
              service_send_cmd "speaker" "connect"              
            fi
            ;;
        "pair"*)
            #scan on
            #scan off
            #trusct 
            #connect
            #pair
            
            ;;
        "stop"*)
            ;; 
      esac
    fi
  done
}



function audio_service() {
  echo "Audio Service"
  mosquitto_sub -t "$AUDIO_TOPIC" > $AUDIO_CMD_PIPE & 
  local spkr_volctl=""
  local REC_DEV=""
  local playback_dev=""

  while true
  do
    if read cmd <$AUDIO_CMD_PIPE; 
    then
      echo "Audio Service received command : $cmd"
      case "$cmd" in
        "vol"*)
          echo "volume up"
          vol=$(echo "$cmd" | cut -d= -f2)
          amixer -D bluealsa sset "$spkr_volctl" "$vol" &> /dev/null
          ;;
        "mute"*)
          echo "volume toggle"
          amixer -D bluealsa sset "$spkr_volctl"  toggle &> /dev/null
          ;;
        "play"*)
          echo "Starting playback..."
          amixer -D bluealsa sset "$spkr_volctl" "30%" 
          
          #play in a subshell 
          (
          cpu_priority="chrt -r 99"
          $cpu_priority AUDIODEV=$REC_DEV      rec  $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer - $EFFECTS  | \
          $cpu_priority AUDIODEV=$playback_dev play $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer -              
          ) &

          #something went wrong 
          service_send_cmd "speaker" "connect"
          ;;
        "REC_DEV"*) 
          REC_DEV=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "playback_dev"*)
          playback_dev=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "spkr_volctl"*)
          spkr_volctl=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "EFFECTS"*)
          EFFECTS=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "stop"*)
          sleep 10000
          ;;
      esac
    fi
  done
}


#This service will dispatch msgs to local services
function main_service() 
{
  echo "Main Service"
  mosquitto_sub -t "$MAIN_TOPIC" > $MAIN_CMD_PIPE & 

  while true
  do
    if read cmd <$MAIN_CMD_PIPE; 
    then      
      echo "Received cmd : $cmd"
      case "$cmd" in
        #try to pair and conntct ao a specific speaker
        "connect"*) 
          #format: connect=SPEAKER_NAME_PREFIX
          spkr_name_prefix=$(echo "$cmd" | cut -d= -f2)
          service_send_cmd "speaker" "connect" "$spkr_name_prefix"
          ;;
        #send effects to sox
        "effects"*)
          ;;

        #volume control
        "vol"*)
          #format: vol=5%+ , 5%- , 1db+ , 1db- 
          val=$(echo "$cmd" | cut -d= -f2)
          service_send_cmd "audio" "vol" "$val"
          ;;

        "mute"*)
          service_send_cmd "audio" "mute"          
          ;;

        "reboot"*)
          reboot
          ;;
        "poweroff"*)
          poweroff
          ;;
      esac

    fi
  done
}


main_service & 
sleep 1
speaker_service &
sleep 1
audio_service &
sleep 2
service_send_cmd "speaker" "load_last"

while true :
do
  sleep 6000
done
