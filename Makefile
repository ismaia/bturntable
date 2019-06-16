install:
	cp bturnplay.sh /usr/bin/bturnplay
	mkdir -p $(HOME)/.bturntable
	cp conf/noise.prof $(HOME)/.bturntable

uninstall:
	rm  /usr/bin/bturnplay
	rm -rf mkdir -p $(HOME)/.bturntable
