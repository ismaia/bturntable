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
SPKR_TOPIC="btt/speaker"
AUDIO_TOPIC="btt/audio"

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
HOST_BDADDR=$(hciconfig dev | grep -o "[[:xdigit:]:]\{11,17\}")


if [ ! -d "$CONF_DIR" ]; then
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
  spkr_bdaddr_dbus=""
  conn_retry=1
  old_name_prefix="old"
  pair_retry=1

  while true
  do
    if read cmd < "$SPKR_PIPE"; 
    then
      echo "speaker command : $cmd"
      case "$cmd" in     
        "connect"*)   
            spkr_name_prefix=$(echo "$cmd" | cut -d@ -f2)                

            if [ "$old_name_prefix" != "$spkr_name_prefix" ];
            then
              #kill current playing
              killall rec &>/dev/null
              killall play &>/dev/null

              old_name_prefix=$spkr_name_prefix
              service_exec_cmd "speaker" "load_config"
              continue #wait the next cmd           
            fi
            
            echo "Trying to connect speaker [$spkr_name] , [$spkr_bdaddr] ,  attempt $conn_retry of 10"
            #dbus connect method call 
            spkr_bdaddr_dbus=$(echo $spkr_bdaddr | tr : _)            
            
            local connect_request=$(dbus-send --system  --reply-timeout=3000 --dest=org.bluez --print-reply --type=method_call \
                                            /org/bluez/hci0/dev_$spkr_bdaddr_dbus org.bluez.Device1.Connect &> /dev/null)
            $connect_request

            local conn_reply=$(dbus-send --system --reply-timeout=3000 --dest=org.bluez --print-reply \
                                            /org/bluez/hci0/dev_$spkr_bdaddr_dbus org.freedesktop.DBus.Properties.Get \
                                            string:"org.bluez.Device1" string:"Connected" 2> /dev/null)

            conn_reply=$(echo "$conn_reply" | awk '/true|false/{print $3}')
                        
            if [ "$conn_reply" == "true" ];
            then              
              echo "Speaker $spkr_bdaddr connected"
              #passing variables to audio service                                          
              spkr_volctl="'$spkr_name - A2DP'"
              playback_dev="bluealsa:HCI=hci0,DEV=$spkr_bdaddr,PROFILE=a2dp"
              
              service_exec_cmd "audio" "playback_dev" "$playback_dev"
              sleep 0.4
              service_exec_cmd "audio" "spkr_volctl"  "$spkr_volctl"
              sleep 0.4
              service_exec_cmd "audio" "rec_dev"      "$rec_dev"
              sleep 0.4
              service_exec_cmd "audio" "spkr_name"    "$spkr_name"
              sleep 0.4
              service_exec_cmd "audio" "bttplay"
              conn_retry=1
            else
              echo "Can't connect speaker!"
              sleep 20          
              if [ $conn_retry -lt 10 ];
              then
                conn_retry=$((conn_retry+1))
                service_exec_cmd "speaker" "connect" "$spkr_name_prefix"              
              else               
                echo "sleep!"
                continue #fail, wait the next cmd
              fi
            fi
            ;;

        "load_config"*)
            
            #check paired speakers
            coproc bluetoothctl
            sleep 1
            echo -e 'paired-devices\n' >&${COPROC[1]}
            sleep 1
            echo -e 'exit\n' >&${COPROC[1]}
            
            #match spkr_name_prefix between paired devices
            local output=$(cat <&${COPROC[0]})
            spkr_bdaddr=$(echo "$output"  | grep -v -E 'NEW|CHG' | grep -i "Device.*$spkr_name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
            spkr_bdaddr=$(echo "$spkr_bdaddr" | awk '{$1=$1;print}' | uniq) 
            spkr_name=$(echo "$output"  | grep -i "Device.*$spkr_name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
            spkr_name=$(echo "$spkr_name" | awk '{$1=$1;print}' | uniq)            

            #Speaker already paired -> create a config file
            if [ "$spkr_bdaddr" != "" ] && [ "$spkr_name" != "" ];
            then
              pair_retry=1
              echo "Using speaker : [$spkr_name] @ [$spkr_bdaddr]"
              service_exec_cmd "speaker" "connect" "$spkr_name_prefix"
            else #Speaker not paired, try to pair
               if [ $conn_retry -lt 10 ] ; then
                  echo "Trying to pair speaker, attempt $pair_retry of 10"
                  pair_retry=$((pair_retry+1))
                  service_exec_cmd "speaker" "pair"
               else
                  continue #failed to pair, wait next cmd
               fi
            fi
            ;;

        "pair"*)  
  
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
            
            #match spkr_name_prefix between discovered devices
            local output=$(cat <&${COPROC[0]})
            spkr_bdaddr=$(echo "$output"  | grep -v -E 'NEW|CHG' | grep -i "Device.*$spkr_name_prefix"  | grep -o "[[:xdigit:]:]\{11,17\}")
            spkr_bdaddr=$(echo "$spkr_bdaddr" | awk '{$1=$1;print}' | uniq) 
            spkr_name=$(echo "$output"  | grep -i "Device.*$spkr_name_prefix" | sed -e 's/.*Device.*[[:xdigit:]:]\{11,17\}//g')
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
            sleep 1
            
            #suposed to be paired at this point, try to create a conf file
            service_exec_cmd "speaker" "load_config"
            ;;
      esac
    fi
  done
}



function audio_service() {
  #audio params
  local spkr_volctl=""
  local spkr_name=""
  local rec_dev="plughw:1,0"
  local playback_dev=""
  local sr="44100"
  local buff_sz="2048"
  local br="16"  
  local sox_logs="-V1 -q"
  local sox_effects="noisered $CONF_DIR/noise.prof 0.30 : riaa :  bass +15 : treble 1"
  if [ ! -f "$CONF_DIR/noise.prof" ] ; then #noise profile does not exists
    sox_effects="riaa :  bass +15 : treble 1"
  fi

  echo "Audio Service"
  mosquitto_sub -t "$AUDIO_TOPIC" > $AUDIO_PIPE & 


  while true
  do
    if read cmd <$AUDIO_PIPE; 
    then
      echo "audio command : $cmd"
      case "$cmd" in
        "vol"*)          
          vol=$(echo "$cmd" | cut -d@ -f2)
          amixer -D bluealsa sset "$spkr_volctl" "$vol" &>/dev/null 
          ;;
        "mute"*)        
          amixer -D bluealsa sset "$spkr_volctl"  toggle &>/dev/null
          ;;
        "bttplay"*)
          echo "Starting audio playback on $spkr_name ..."
          amixer -D bluealsa sset "$spkr_volctl" "35%" 

          #play in a subshell 
          (
            AUDIODEV="$rec_dev" rec  $sox_logs --buffer $buff_sz -c 1 -t wav -r $sr -b $br -e signed-integer - $sox_effects  | \
            AUDIODEV="$playback_dev" play $sox_logs --buffer $buff_sz -c 1 -t wav -r $sr -b $br -e signed-integer -            
            sleep 5
          ) &
          
          sleep 0.5
          rec_pid=$(pgrep -a rec | grep wav | cut -d" " -f1) 
          play_pid=$(pgrep -a play | grep wav | cut -d" " -f1) 
          bluealsa_pid=$(pgrep -a bluealsa | grep /usr/bin/bluealsa | cut -d" " -f1)
          
          #cpu rt priority to audio processes
          chrt -p 99 $bluealsa_pid &>/dev/null          
          chrt -p 99 $rec_pid      &>/dev/null
          chrt -p 99 $play_pid     &>/dev/null
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
        "spkr_name"*)
          spkr_name=$(echo "$cmd" | cut -d@ -f2)
          ;;          
        "sox_effects"*)
          sox_effects=$(echo "$cmd" | cut -d@ -f2)
          ;;
        "stop"*)
          killall rec &>/dev/null
          killall play &>/dev/null
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
        "effects"*)
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

while true :
do
  sleep 6000
done
