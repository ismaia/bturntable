#!/bin/bash

#the full directory name of the script no matter where it is being called from
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MAIN_TOPIC="main_cmds"
SPKR_TOPIC="spkr_cmds"
AUDIO_TOPIC="audio_cmds"

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
BUF_SZ=4096
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
  case "$srv" in
    "speaker"*)
      (sleep 0.4 ; mosquitto_pub -t "$SPKR_TOPIC" -m "$cmd" ) &
      ;;
    "audio"*)
      (sleep 0.4 ; mosquitto_pub -t "$AUDIO_TOPIC" -m "$cmd" ) &
      ;;
    "main"*)
      (sleep 0.4 ; mosquitto_pub -t "$AUDIO_TOPIC" -m "$cmd" ) &
      ;;
  esac
   
}

#Select a paired speaker by name prefix 
function speaker_select() {
  local name_prefix="$1"
  local SPKR_BDADDR=""
  local SPKR_NAME=""

  coproc bluetoothctl
  sleep 1
  echo -e 'paired-devices\n' >&${COPROC[1]}
  sleep 1
  echo -e 'exit\n' >&${COPROC[1]}
  
  local output=$(cat <&${COPROC[0]})
  SPKR_BDADDR=$(echo "$output"  | grep -i "Device.*$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
  SPKR_BDADDR=$(echo "$SPKR_BDADDR" | awk '{$1=$1;print}' | uniq) #trim 
  SPKR_NAME=$(echo "$output"  | grep -i "Device.*$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
  SPKR_NAME=$(echo "$SPKR_NAME" | awk '{$1=$1;print}' | uniq) #trim
  
  if [ "$SPKR_BDADDR" != "" ];
  then
    echo "Selected speaker $SPKR_NAME @ $SPKR_BDADDR"
    echo "$SPKR_BDADDR" > "$SPKR_CONF_FILE"
    echo "$SPKR_NAME" >> "$SPKR_CONF_FILE"
  fi
}

#Pair a speaker by name prefix 
function speaker_pair() {
  name_prefix="$1"
  coproc bluetoothctl
  sleep 2
  #find SPKR_BDADDR and SPKR_NAME
  sleep 2
  echo -e 'scan on\n' >&${COPROC[1]}
  sleep 15
  echo -e 'devices\n' >&${COPROC[1]}
  sleep 1   
  echo -e 'scan off\n' >&${COPROC[1]}
  sleep 1
  echo -e 'exit\n' >&${COPROC[1]}
  local output=$(cat <&${COPROC[0]})
  local SPKR_BDADDR=$(echo "$output" | grep -i "$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
  local SPKR_BDADDR=$(echo "$SPKR_BDADDR" | uniq)
  local SPKR_NAME=$(echo "$output" | grep -i "$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
  local SPKR_NAME=$(echo "$SPKR_NAME" | awk '{$1=$1;print}' | uniq)
  coproc bluetoothctl
  sleep 2
  #pair SPKR_BDADDR
  echo -e 'scan on\n' >&${COPROC[1]}
  sleep 5
  echo -e "trust $SPKR_BDADDR \n" >&${COPROC[1]}
  sleep 2
  echo -e "pair $SPKR_BDADDR \n" >&${COPROC[1]}
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
  local SPKR_BDADDR=""
  local SPKR_NAME=""
  local SPKR_VOLCTL=""
  local PLAYBACK_DEV=""
  local DBUS_ADDR=""

  while true
  do
    if read cmd < "$SPKR_CMD_PIPE"; 
    then
      echo "Speaker Service received command : $cmd"
      case "$cmd" in     
        "load_conf"*)
            if [ -f "$SPKR_CONF_FILE" ]; then
              SPKR_BDADDR=$(cat "$SPKR_CONF_FILE" | head -1)
              SPKR_NAME=$(cat "$SPKR_CONF_FILE" | tail -1)
              SPKR_VOLCTL="'$SPKR_NAME - A2DP'"
              PLAYBACK_DEV="bluealsa:HCI=hci0,DEV=$SPKR_BDADDR,PROFILE=a2dp"
              DBUS_ADDR=$(echo $SPKR_BDADDR | tr : _)
              echo "Loaded Speaker parameters: [$SPKR_NAME] , [$SPKR_BDADDR]"
              
              #passing variables to audio service
              service_send_cmd "audio" "PLAYBACK_DEV@$PLAYBACK_DEV"                
              service_send_cmd "audio" "SPKR_VOLCTL@$SPKR_VOLCTL"
              service_send_cmd "audio" "REC_DEV@$REC_DEV"               
              service_send_cmd "audio" "EFFECTS@$EFFECTS"
              service_send_cmd "speaker" "connect"
            fi
            ;;
        "connect"*)
            echo "Trying to connect speaker [$SPKR_NAME] , [$SPKR_BDADDR] ..."
            local conn_status_cmd=$(dbus-send --system --reply-timeout=2000 --dest=org.bluez --print-reply /org/bluez/hci0/dev_$DBUS_ADDR org.freedesktop.DBus.Properties.Get string:"org.bluez.Device1" string:"Connected" 2> /dev/null)
            conn_status=$(echo "$conn_status_cmd" | awk '/true|false/{print $3}')
            sleep 2
            if [ "$conn_status" == "true" ];
            then
              echo "Speaker $SPKR_BDADDR connected"
              service_send_cmd "speaker" "play"
            else
              echo "Speaker not connected, retrying..."
              sleep 10
              dbus-send --system  --reply-timeout=2000 --dest=org.bluez --print-reply --type=method_call /org/bluez/hci0/dev_$DBUS_ADDR org.bluez.Device1.Connect &> /dev/null
              service_send_cmd "speaker" "connect"              
            fi
            ;;
        "select"*)
            echo "Selecting speaker..."
            prefix=$(echo "$cmd" | cut -d= -f2) 
            speaker_select "$prefix" 
            if [ -f "$SPKR_CONF_FILE" ]; 
            then
              service_send_cmd "speaker" "load_conf"
            else
              echo "No paired speaker found, trying to pair speaker [$prefix] ..."
              speaker_pair "$prefix"
            fi
            ;;
        "play"*)
            echo "Starting playback..."
            amixer -D bluealsa sset "$SPKR_VOLCTL" "30%" 
            AUDIODEV=$REC_DEV      rec  $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer - $EFFECTS  | \
            AUDIODEV=$PLAYBACK_DEV play $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer -              
            #something went wrong 
            service_send_cmd "speaker" "connect"
            ;;
        "stop"*)
            sleep 10000
            ;; 
      esac
    fi
  done
}



function audio_service() {
  echo "Audio Service"
  mosquitto_sub -t "$AUDIO_TOPIC" > $AUDIO_CMD_PIPE & 

  while true
  do
    if read cmd <$AUDIO_CMD_PIPE; 
    then
      echo "Audio Service received command : $cmd"
      case "$cmd" in
        "vol"*)
          echo "volume up"
          vol=$(echo "$cmd" | cut -d= -f2)
          amixer -D bluealsa sset "$SPKR_VOLCTL" "$vol" &> /dev/null
          ;;
        "mute"*)
          echo "volume toggle"
          amixer -D bluealsa sset "$SPKR_VOLCTL"  toggle &> /dev/null
          ;;
        "REC_DEV"*) 
          REC_DEV=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "PLAYBACK_DEV"*)
          PLAYBACK_DEV=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "SPKR_VOLCTL"*)
          SPKR_VOLCTL=$(echo "$cmd" | cut -d@ -f2)
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

function main_service() 
{
  echo "Main Service"
  mosquitto_sub -t "$MAIN_TOPIC" > $MAIN_CMD_PIPE & 

  while true
  do
    if read cmd <$MAIN_CMD_PIPE; 
    then      
      echo "Main Service received command : $cmd"
      case "$cmd" in
        "reboot"*)
          reboot
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
service_send_cmd "speaker" "load_conf"

while true :
do
  sleep 6000
done
