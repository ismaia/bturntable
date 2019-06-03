# BTurntable : Making a vintage turntable connect to a bluetooth speaker


### Intro
 ![AF180](images/af180.jpg)

When my nice yellow philips vinyl turntable (AF180) broke I was very sad and decided to fix it, but instead of fixing the old electronic components I had an idea: why not connect my turntable to a Bluetooth speaker ? 

Turntable devices can be adapted with a [RIAA phono preamplifier](http://sound.whsites.net/project06.htm)  who is a perfect match but these modules are usually expensive

Instead of buying relatively expensive electronics (RIAA module + power supply), I decided to try a cheap solution  ( ~ $2 ) : *An USB audio adapter*

![](images/usb_audio_adapter.jpg)

As the turntable's cartridge produce very small voltage levels (uV ~ mV ) the mic preamp inside the USB adapter is certainly not a perfect match but **it worked very well after my first tests**.
Once we're in digital domain we can improve sound quality by doing some equalization,  noise removal and everything we want, including RIAA equalization. We can do it all these with a swiss knife called SoX

The main advantage of this approach is that if you have a bt speaker (almost sure!) you can build this system for less than $20 (rpi zero + usb hub + audio usb adapter + jack cable)

As I already had a raspberry pi3 and a good UBS BT adapter I preferred to use them but nothing prevents you from running the system on a raspberry pi zero w (TODO)

[You can check the video on YouTube](youtube.com)


### Parts

* A Raspberry PI zero or a Raspberry PI 3
* Any Audio USB Adapter that works on linux
* 3.5 mm jack cable mono (red,white and black wires)

### Wiring

 * **Cartridge** : As we want to send audio over a small bluetooth speaker, it makes no sense separating left and right channels from the cartridge. We must mix the two channels by shorting both wires into a single one. This wire will have a signal mixed from two channels. An advantage is that doing this approach we'll need a single audio usb adapter instead of two. As mic input is always mono this approach will carry the mixed signal into the mic input

 ![Cartridge wiring](images/cartridge_wiring.png)

 * **Ground** : To avoid noise make sure that all grounds are connected together, even the wire coming from the outlet. Don't forget to connect all these on the turntable's metal case

 * **3.5 mm jack cable**
 ![Jack wiring](images/jack_wiring.png)


 * All system connections


### Installing Dependencies

I decided to use alsa because pulseaudio was not responsive and gave big latency in my tests, but if you want to use pulseaudio i'll give you the command at the end of this section

On the Raspberry pi : 
``` 
 apt install bluez-alsa sox
```

### Running 

#### Pairing and connecting the bt speaker 

```
#bluetoothctl
[bluetooth]# agent on
Agent registered
[bluetooth]# scan on

XX:XX:XX:XX:XX #our speaker 

[bluetooth]# pair XX:XX:XX:XX:XX

[bluetooth]# trust XX:XX:XX:XX:XX

[bluetooth]# connect XX:XX:XX:XX:XX

``` 


Make sure you can see your bt speaker on your rpi :
``` 
aplay -l 
``` 


Make sure you can see your audio usb dongle on your rpi :
``` 
arecord -l 
``` 




### Shutdown Module (Optional)

 I included a switch in my turntable to turn off the system. In order to avoid wearing out the Rpi and the sdcard when turntable turns off I developed a small power swich which can turn off the raspberry pi when the main switch turns off the system. For this circuit you'll need some aditional components :
 * 1x Voltage regulator
 * 2x transistors (used here as logic inverters)
 * 2x 18650 ion-Lithium batteries
 * 2x 1k resistors 





 

