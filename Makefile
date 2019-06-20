install:
	cp btt.sh /usr/bin/btt
	mkdir -p $(HOME)/.bturntable
	cp conf/noise.prof $(HOME)/.bturntable
	cp conf/systemd_bturntable.service /etc/systemd/system/bturntable.service
	chmod 644 /etc/systemd/system/bturntable.service

uninstall:
	rm -f /usr/bin/btt
	rm -rf $(HOME)/.bturntable
	rm -f /etc/systemd/system/bturntable.service

