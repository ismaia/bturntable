#!/bin/bash

#the full directory name of the script no matter where it is being called from
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MQTT_TOPIC="cmdctl"

MQTT_CMD_PIPE="/tmp/cmdctl"
SPKR_CMD_PIPE="/tmp/spkctl"
AUDIO_CMD_PIPE="/tmp/audioctl"

#creating all pipes
[ -p "$MQTT_CMD_PIPE" ] || mkfifo -m 0600 "$MQTT_CMD_PIPE" || exit 1
#[ -p "$SPKR_CMD_PIPE" ] || mkfifo -m 0600 "$SPKR_CMD_PIPE" || exit 1
#[ -p "$AUDIO_CMD_PIPE" ] || mkfifo -m 0600 "$AUDIO_CMD_PIPE" || exit 1


CONF_DIR=="$HOME/.bturntable"
SPKR_CONF_FILE="$CONF_DIR/speaker.conf"
HOST_BDADDR=$(hciconfig dev | grep -o "[[:xdigit:]:]\{11,17\}")

#audio params
REC_DEV="plughw:1,0"
PLAYBACK_DEV=""
SPKR_VOLCTL=""
SR=44100
BUF_SZ=4096
BR=16
EFFECTS="noisered $PRJ_DIR/conf/noise.prof 0.30 : riaa :  bass +10 : treble 5"
VERBOSE="-V1 -q"

if [ -d "$CONF_DIR" ]; then
  mkdir -p "$CONF_DIR"
fi


function exec_service_cmd() {
  service=$1
  cmd=$2
  case $service in
    "speaker"*)
      echo "$cmd" > "$SPKR_CMD_PIPE"
      ;;
    "audio"*)
      echo "$cmd" > "$AUDIO_CMD_PIPE"
      ;;
    "mqtt"*)
      echo "$cmd" > "$MQTT_CMD_PIPE"
      ;;
    "stop")
      ;;
  esac
}


# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
function ctrl_c() {
   echo "Terminating..."
   killall play &> /dev/null
   killall rec  &> /dev/null
   killall mosquitto_sub &> /dev/null
   killall mqtt_service &> /dev/null
   killall audio_service &> /dev/null
   killall speaker_service &> /dev/null
   exit
}



#Select a paired speaker by name prefix 
function speaker_select() {
  local name_prefix="$1"
  SPKR_BDADDR=""
  SPKR_NAME=""
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
  SPKR_BDADDR=""
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
  SPKR_BDADDR=$(echo "$output" | grep -i "$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
  SPKR_BDADDR=$(echo "$SPKR_BDADDR" | uniq)
  SPKR_NAME=$(echo "$output" | grep -i "$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
  SPKR_NAME=$(echo "$SPKR_NAME" | awk '{$1=$1;print}' | uniq)
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
  echo "Speaker service"
  while true
  do
    if read cmd < "$SPKR_CMD_PIPE"; 
    then #blocking read
      echo "speaker_service received cmd"
    fi

    while true
    do
      case $cmd in
          "load_conf"*)
              if [ -f "$SPKR_CONF_FILE" ]; then
                SPKR_BDADDR=$(cat "$SPKR_CONF_FILE" | head -1)
                SPKR_NAME=$(cat "$SPKR_CONF_FILE" | tail -1)
                SPKR_VOLCTL="'$SPKR_NAME - A2DP'"
                PLAYBACK_DEV="bluealsa:HCI=hci0,DEV=$SPKR_BDADDR,PROFILE=a2dp"
                DBUS_ADDR=$(echo $SPKR_BDADDR | tr : _)
                
                #passing variables to audio service
                echo "PLAYBACK_DEV@$PLAYBACK_DEV" > "$AUDIO_CMD_PIPE"
                echo "SPKR_VOLCTL@$SPKR_VOLCTL" > "$AUDIO_CMD_PIPE"
                echo "REC_DEV@$REC_DEV" > "$AUDIO_CMD_PIPE"
                echo "EFFECTS@$EFFECTS" > "$AUDIO_CMD_PIPE"
                
                echo "Loaded Speaker parameters: [$SPKR_NAME] , [$SPKR_BDADDR]"
                sleep 1
                cmd="connect"
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
                echo "play" > "$AUDIO_CMD_PIPE"
                break #goto cmd read
              else
                echo "Speaker not connected!"
                dbus-send --system  --reply-timeout=2000 --dest=org.bluez --print-reply --type=method_call /org/bluez/hci0/dev_$DBUS_ADDR org.bluez.Device1.Connect &> /dev/null
              fi
              ;;
          "select"*)
              prefix=$(echo "$cmd" | cut -d= -f2) 
              speaker_select "$prefix" 
              if [ "$SPKR_BDADDR" == "" ]; 
              then
                echo "No paired speaker found, trying to pair speaker [$prefix] ..."
                speaker_pair "$prefix"
              else
                cmd="load_conf" 
              fi
              ;;
          "stop"*)
              sleep 10000
              ;;
            
      esac
    done

  done
}



function audio_service() {
  echo "Audio service"

  while true
  do
    if read cmd < "$AUDIO_CMD_PIPE"; then
      case $cmd in
        "vol+"*)
          echo "volume up"
          vol=$(echo "$cmd" | cut -d= -f2)
          amixer -D bluealsa set "$SPKR_VOLCTL" "$vol"
          ;;
        "vol-"*)
          echo "volume down"
          vol=$(echo "$cmd" | cut -d= -f2)
          amixer -D bluealsa set "$SPKR_VOLCTL" "$vol"
          ;;
        "mute"*)
          echo "volume toggle"
          amixer -D bluealsa set "$SPKR_VOLCTL"  toggle
          ;;
        "play"*)
          echo "Starting playback..."
          AUDIODEV=$REC_DEV      rec  $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer - $EFFECTS  | \
          AUDIODEV=$PLAYBACK_DEV play $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer - 
          sleep 10
          #something went wrong 
          echo "connect" > "$SPKR_CMD_PIPE"
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

function mqtt_service() 
{
  echo "MQTT service"
  
  mosquitto_sub -t "$MQTT_TOPIC" > "$MQTT_CMD_PIPE" &

  while true
  do
    if read cmd < $MQTT_CMD_PIPE; then      
      echo "received command $cmd"
      case $cmd in
        "speaker"*) #format : speaker cmd=val
          echo "speaker cmd : $cmd"
          echo "$cmd" > "$SPKR_CMD_PIPE"
          ;;
        "audio"*) #format : audio cmd=val
          echo "audio cmd : $cmd"
          echo "$cmd" > "$AUDIO_CMD_PIPE"
          ;;
        "reboot"*)
          reboot
          ;;
      esac
    fi
  done
}


mqtt_service &
sleep 1
#speaker_service &
#sleep 1
#audio_service &
#sleep 1
#exec_service_cmd "speaker" "load_conf"

while true :
do
  sleep 6000
done
