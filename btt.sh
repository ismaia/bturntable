#!/bin/bash

#the full directory name of the script no matter where it is being called from
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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


MAIN_TOPIC="btt"
SPKR_TOPIC="speaker"
AUDIO_TOPIC="audio"

MAIN_PIPE="/tmp/btt_pipe"
SPKR_PIPE="/tmp/btt_spk_pipe"
AUDIO_PIPE="/tmp/btt_audio_pipe"

trap "rm -f $MAIN_PIPE" exit
trap "rm -f $SPKR_PIPE" exit
trap "rm -f $AUDIO_PIPE" exit

if [[ ! -p $MAIN_PIPE ]]; then
  mkfifo $MAIN_PIPE
fi

if [[ ! -p $SPKR_PIPE ]]; then
  mkfifo $SPKR_PIPE
fi

if [[ ! -p $AUDIO_PIPE ]]; then
  mkfifo $AUDIO_PIPE
fi

#global variables
CONF_DIR="$HOME/.bturntable"
SPKR_CONF_FILE="$CONF_DIR/speaker.conf"
HOST_BDADDR=$(hciconfig dev | grep -o "[[:xdigit:]:]\{11,17\}")


if [ -d "$CONF_DIR" ]; then
  mkdir -p "$CONF_DIR"
fi


function service_exec_cmd() {
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
      (sleep 0.4 ; mosquitto_pub -t "$MAIN_TOPIC" -m "$cmd""@""$val" ) &
      ;;
  esac
}



function speaker_service() 
{    
  echo "Speaker Service"
  mosquitto_sub -t "$SPKR_TOPIC" > "$SPKR_PIPE" & 
  spkr_bdaddr=""
  spkr_name=""
  spkr_volctl=""
  playback_dev=""
  rec_dev="plughw:1,0"
  dbus_addr=""


  while true
  do
    if read cmd < "$SPKR_PIPE"; 
    then
      echo "speaker command : $cmd"
      case "$cmd" in     
        "connect"*)   
            name_prefix=$(echo "$cmd" | cut -d@ -f2)            

            #select another speaker
            if [ "$name_prefix" != "last_speaker" ] ; 
            then 
              #stop running audio services
              killall rec &>/dev/null
              killall play &>/dev/null
              service_exec_cmd "speaker" "config" "$name_prefix"
              continue #read the next command 
            fi

            #check is a config exists
            if [ -f "$SPKR_CONF_FILE" ]; then
              spkr_bdaddr=$(cat "$SPKR_CONF_FILE" | head -1)
              spkr_name=$(cat "$SPKR_CONF_FILE" | tail -1)
              dbus_addr=$(echo $spkr_bdaddr | tr : _)
                                          
              spkr_volctl="'$spkr_name - A2DP'"
              playback_dev="bluealsa:HCI=hci0,DEV=$spkr_bdaddr,PROFILE=a2dp"
              dbus_addr=$(echo $spkr_bdaddr | tr : _)
              echo "Loaded Speaker parameters: [$spkr_name] , [$spkr_bdaddr]"              
            else
              service_exec_cmd "speaker" "config" "$name_prefix"
              continue
            fi

            conn_retry=1
            echo "Trying to connect speaker [$spkr_name] , [$spkr_bdaddr] ... , attempt $conn_retry of 10"
            dbus-send --system  --reply-timeout=3000 --dest=org.bluez --print-reply --type=method_call /org/bluez/hci0/dev_$dbus_addr org.bluez.Device1.Connect &> /dev/null
            local conn_status_cmd=$(dbus-send --system --reply-timeout=2000 --dest=org.bluez --print-reply /org/bluez/hci0/dev_$dbus_addr org.freedesktop.DBus.Properties.Get string:"org.bluez.Device1" string:"Connected" 2> /dev/null)
            conn_status=$(echo "$conn_status_cmd" | awk '/true|false/{print $3}')            
            
            if [ "$conn_status" == "true" ];
            then
              echo "Speaker $spkr_bdaddr connected"
              #passing variables to audio service
              service_exec_cmd "audio" "playback_dev" "$playback_dev"
              sleep 0.4
              service_exec_cmd "audio" "spkr_volctl"  "$spkr_volctl"
              sleep 0.4
              service_exec_cmd "audio" "rec_dev"      "$rec_dev"
              sleep 0.4
              service_exec_cmd "audio" "sox_effects"  "$sox_effects"
              sleep 0.4
              service_exec_cmd "audio" "bttplay"
            else
              echo "Speaker not connected, retrying..."
              conn_retry=$((conn_retry+1))
              sleep 10          

              if [ "$conn_retry" -lt 10 ] ;
              then
                service_exec_cmd "speaker" "connect"              
              else
                continue #fail, wait the next cmd
              fi
            fi
            ;;

        "config"*)
            name_prefix=$(echo "$cmd" | cut -d@ -f2)            

            #check paired speakers
            coproc bluetoothctl
            sleep 1
            echo -e 'paired-devices\n' >&${COPROC[1]}
            sleep 1
            echo -e 'exit\n' >&${COPROC[1]}
            
            local output=$(cat <&${COPROC[0]})
            spkr_bdaddr=$(echo "$output"  | grep -i "Device.*$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
            spkr_bdaddr=$(echo "$spkr_bdaddr" | awk '{$1=$1;print}' | uniq) 
            spkr_name=$(echo "$output"  | grep -i "Device.*$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
            spkr_name=$(echo "$spkr_name" | awk '{$1=$1;print}' | uniq)
            
            #Speaker already paired -> create a config file
            if [ "$spkr_bdaddr" != "" ];
            then
              echo "Using speaker : [$spkr_name] @ [$spkr_bdaddr]"
              echo "$spkr_bdaddr" > "$SPKR_CONF_FILE"
              echo "$spkr_name" >> "$SPKR_CONF_FILE"
              service_exec_cmd "speaker" "connect" "$name_prefix"
            else #Speaker not paired, try to pair
              service_exec_cmd "speaker" "pair" "$name_prefix"
            fi
            ;;

        "pair"*)  
            name_prefix=$(echo "$cmd" | cut -d@ -f2)
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
            
            #match name_prefix between discovered devices
            local output=$(cat <&${COPROC[0]})
            spkr_bdaddr=$(echo "$output" | grep -i "$name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
            spkr_bdaddr=$(echo "$spkr_bdaddr" | uniq)
            spkr_name=$(echo "$output" | grep -i "$name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
            spkr_name=$(echo "$spkr_name" | awk '{$1=$1;print}' | uniq)
            
          
            coproc bluetoothctl
            sleep 2
            #pair spkr_bdaddr
            echo -e "trust $spkr_bdaddr \n" >&${COPROC[1]}
            sleep 1
            echo -e "connect $spkr_bdaddr \n" >&${COPROC[1]}
            sleep 2  
            echo -e "pair $spkr_bdaddr \n" >&${COPROC[1]}
            sleep 10
            echo -e "disconnect $spkr_bdaddr \n" >&${COPROC[1]}  
            sleep 1
            echo -e 'exit\n' >&${COPROC[1]}                  
            ;;
      esac
    fi
  done
}



function audio_service() {
  #audio params
  local spkr_volctl=""
  local rec_dev="plughw:1,0"
  local playback_dev=""
  local sr="44100"
  local buff_sz="2048"
  local br="16"
  local sox_effects="noisered $CONF_DIR/noise.prof 0.30 : riaa :  bass +10 : treble 5"
  local sox_logs="-V1 -q"

  echo "Audio Service"
  mosquitto_sub -t "$AUDIO_TOPIC" > $AUDIO_PIPE & 


  while true
  do
    if read cmd <$AUDIO_PIPE; 
    then
      echo "audio command : $cmd"
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
        "bttplay"*)
          echo "Starting playback..."
          amixer -D bluealsa sset "$spkr_volctl" "60%" 

          export rec_dev="$rec_dev"
          export playback_dev="$playback_dev"
          export sox_logs="$sox_logs"
          export buff_sz="$buff_sz"
          export sr="$sr"
          export br="$br"
          export sox_effects="$sox_effects"

          #play in a subshell 
          (
    
            echo "AUDIODEV=$rec_dev rec $sox_logs --buffer $buff_sz -c 1 -t wav -r $sr -b $br -e signed-integer - $sox_effects"
            echo "AUDIODEV=$playback_dev play $sox_logs --buffer $buff_sz -c 1 -t wav -r $sr -b $br -e signed-integer -"
            
            AUDIODEV="$rec_dev" rec  $sox_logs --buffer $buff_sz -c 1 -t wav -r $sr -b $br -e signed-integer - $sox_effects  | \
            AUDIODEV="$playback_dev" play $sox_logs --buffer $buff_sz -c 1 -t wav -r $sr -b $br -e signed-integer -            
            
            #something went wrong above
            service_exec_cmd "speaker" "connect" "last_speaker"
          ) &
            
            rec_pid=$(pgrep -a rec | grep signed-integer | cut -d" " -f1)
            play_pid=$(pgrep -a play | grep signed-integer | cut -d" " -f1) 
            bluealsa_pid=$(pgrep -a bluealsa | grep /usr/bin/bluealsa | cut -d" " -f1)
            
            #cpu rt priority to audio processes
            chrt -p 99 $bluealsa_pid            
            chrt -p 99 $rec_pid
            chrt -p 99 $play_pid


          ;;
        "rec_dev"*) 
          rec_dev=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "playback_dev"*)
          playback_dev=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "spkr_volctl"*)
          spkr_volctl=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "sox_effects"*)
          sox_effects=$(echo "$cmd" | cut -d@ -f2)
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
  echo "MQTT Dispatcher Service"
  mosquitto_sub -t "$MAIN_TOPIC" > "$MAIN_PIPE" & 

  while true
  do
    if read cmd <$MAIN_PIPE; 
    then      
      echo "cmd : $cmd"
      case "$cmd" in
        #try to pair and conntct ao a specific speaker
        "connect"*) 
          #format: connect=SPEAKER_NAME_PREFIX
          spkr_name_prefix=$(echo "$cmd" | cut -d= -f2)
          service_exec_cmd "speaker" "connect" "$spkr_name_prefix"
          ;;
        #send sox_effects to sox
        "sox_effects"*)
          ;;

        #volume control
        "vol"*)
          #format: vol=5%+ , 5%- , 1db+ , 1db- 
          val=$(echo "$cmd" | cut -d= -f2)
          service_exec_cmd "audio" "vol" "$val"
          ;;

        "mute"*)
          service_exec_cmd "audio" "mute"          
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
service_exec_cmd "speaker" "connect" "last_speaker"

while true :
do
  sleep 6000
done
