#!/bin/bash

#the full directory name of the script no matter where it is being called from
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

BD_ADDR=C0:28:8D:85:FB:13
DBUS_ADDR=$(echo $BD_ADDR | tr : _)

REC_DEV="plughw:1,0"
PLAYBACK_DEV="bluealsa:HCI=hci0,DEV=C0:28:8D:85:FB:13,PROFILE=a2dp"

SR=44100
BUF_SZ=4096
BR=16
EFFECTS="noisered $SCRIPT_DIR/conf/noise.prof 0.30 : riaa :  treble 10"
VERBOSE="-V1 -q"

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
function ctrl_c() {
   echo "Terminating..."
   killall play &> /dev/null
   killall rec  &> /dev/null
   exit
}


while :
do
  echo "Checking speaker status..."
  conn_status_cmd=$(dbus-send --system --dest=org.bluez --print-reply /org/bluez/hci0/dev_$DBUS_ADDR org.freedesktop.DBus.Properties.Get string:"org.bluez.Device1" string:"Connected")
  conn_status=$(echo "$conn_status_cmd" | awk '/true|false/{print $3}')

  sleep 2

  if [ "$conn_status" == "true" ];
  then
    echo "Speaker $BD_ADDR connected"
  else
    echo "Speaker not connected, trying to connect bt speaker $BD_ADDR..."
    dbus-send --system --dest=org.bluez --print-reply --type=method_call /org/bluez/hci0/dev_$DBUS_ADDR org.bluez.Device1.Connect
  fi

  sleep 5

  if [ "$conn_status" == "true" ];
  then
      amixer -D bluealsa sset 'UE BOOM 2 - A2DP'  35%

      AUDIODEV=$REC_DEV      rec  $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer - $EFFECTS  | \
      AUDIODEV=$PLAYBACK_DEV play $VERBOSE --buffer $BUF_SZ -c 1 -t wav -r $SR -b $BR -e signed-integer -

      #pulseaudio
      #parec --latency-msec=1 -d alsa_input.usb-GeneralPlus_USB_Audio_Device-00.analog-mono | pacat -d bluez_sink.C0_28_8D_85_FB_13.headset_head_unit
  else
   echo "Speaker not connected..."
  fi

  sleep 5

done




