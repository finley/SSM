#
# $Id: Makefile 376 2010-09-01 17:25:40Z finley $
#  vi:set filetype=make noet ai:
#

SHELL = /bin/sh

#
# These settings are what I would expect for most modern Linux distros, 
# and are what work for me unmodified on Ubuntu. -BEF-
# 
package		= simple-state-manager
prefix		= /usr
exec_prefix = ${prefix}
bindir 		= ${DESTDIR}${exec_prefix}/sbin
initdir 	= ${DESTDIR}/etc/init.d
sysconfdir 	= ${DESTDIR}/etc/ssm
mandir		= ${DESTDIR}${prefix}/share/man
docdir 		= ${DESTDIR}/usr/share/doc/${package}
libdir  	= ${DESTDIR}/usr/lib/${package}
rpmbuild    = ~/rpmbuild

VERSION = $(shell cat VERSION)

TOPDIR := $(CURDIR)


.PHONY: all
all:  $(TOPDIR)/tmp/lib/SimpleStateManager.pm

$(TOPDIR)/tmp/lib/SimpleStateManager.pm:  Makefile VERSION $(TOPDIR)/lib/SimpleStateManager.pm
	mkdir -p $(TOPDIR)/tmp/lib
	cp $(TOPDIR)/lib/SimpleStateManager.pm $(TOPDIR)/tmp/lib/SimpleStateManager.pm
	perl -pi -e 's/___VERSION___/${VERSION}/g' $(TOPDIR)/tmp/lib/SimpleStateManager.pm
	mkdir -p $(TOPDIR)/tmp/${package}-$(VERSION)/usr/share/man/man8/
	PERL5LIB=./lib/ ./bin/ssm --help | txt2man | gzip > $(TOPDIR)/tmp/${package}-$(VERSION)/usr/share/man/man8/ssm.8.gz

.PHONY: install
install:  all
	test -d ${sysconfdir} || install -d -m 755 ${sysconfdir}
	test -e ${sysconfdir}/defaults || install -m 644 etc/defaults	${sysconfdir}
	
	test -d ${bindir} || install -d -m 755 ${bindir}
	install -m 755 bin/* 					${bindir}
	
	@test ! -e ${bindir}/system-state-manager || \
		(echo; echo; \
		echo "WARNING: Please remove old binary -> \"sudo rm ${bindir}/system-state-manager\""; \
		echo; echo; \
		echo "Hit <Enter> to continue..."; \
		read i)
	
	#
	# Libs
	#
	test -d ${libdir} || install -d -m 755 ${libdir}
	install -m 644 $(TOPDIR)/tmp/lib/SimpleStateManager.pm ${libdir}/SimpleStateManager.pm
	#
	test -d ${libdir}/SimpleStateManager/ || install -d -m 755 ${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/Aptitude.pm ${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/Dpkg.pm 	${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/Yum.pm  	${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/None.pm  	${libdir}/SimpleStateManager/
		
	#
	# Docs
	#
	test -d ${docdir} || install -d -m 755 ${docdir}
	#	
	rsync -av --exclude '/.*' usr/share/doc/ ${docdir}
	#	
	install -m 644 $(TOPDIR)/CREDITS  	${docdir}
	install -m 644 $(TOPDIR)/README  	${docdir}
	#	
	cat $(TOPDIR)/usr/share/doc/examples/safe_to_run_example_config_file.conf \
		| perl -pi -e 's/^/#/' > ${docdir}/examples/starter_config_file.conf
	#	
	find ${docdir} -type d -exec chmod 0775 '{}' \;
	find ${docdir} -type f -exec chmod 0664 '{}' \;
	
	#
	# Man pages
	#
	test -d ${mandir}/man8 || install -d -m 755 ${mandir}/man8
	install -m 644 $(TOPDIR)/tmp/${package}-$(VERSION)/usr/share/man/man8/ssm.8.gz ${mandir}/man8
	

.PHONY: release
release:  tarball debs rpms
	@echo 
	@echo "I'm about to upload the following files to:"
	@echo "  ~/src/www.systemimager.org/pub/ssm/"
	@echo "-----------------------------------------------------------------------"
	@/bin/ls -1 $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.*
	@echo
	@echo "Hit <Enter> to continue..."
	@read i
	rsync -av --progress $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.* ~/src/www.systemimager.org/pub/ssm/
	@echo
	@echo "Now run:   cd ~/src/www.systemimager.org/ && make upload"
	@echo

.PHONY: rpm
rpm:  rpms

.PHONY: rpms
rpms:  tarball
	@echo Bake them cookies, grandma!
	# Quick hack to get rpmbuild to work on Lucid -- was failing w/bzip2 archive
	# Turn it into a gz archive instead of just tar to avoid confusion about canonical archive -BEF-
	bzcat $(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2 | gzip > $(TOPDIR)/tmp/${package}-$(VERSION).tar.gz 
	rpmbuild -ta $(TOPDIR)/tmp/${package}-$(VERSION).tar.gz
	/bin/cp -i ${rpmbuild}/RPMS/*/${package}-$(VERSION)-*.rpm $(TOPDIR)/tmp/
	/bin/cp -i ${rpmbuild}/SRPMS/${package}-$(VERSION)-*.rpm	$(TOPDIR)/tmp/
	
	/bin/ls -1 $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.*

.PHONY: deb
deb:  debs

.PHONY: debs
debs:  tarball
	ln $(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2 $(TOPDIR)/tmp/${package}_$(VERSION).orig.tar.bz2
	cd $(TOPDIR)/tmp/${package}-$(VERSION) && debuild -us -uc
	/bin/ls -1 $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.*

.PHONY: tarball
tarball:  $(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2.sign
$(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2.sign: $(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2
	cd $(TOPDIR)/tmp && gpg --detach-sign -a --output ${package}-$(VERSION).tar.bz2.sign ${package}-$(VERSION).tar.bz2
	cd $(TOPDIR)/tmp && gpg --verify ${package}-$(VERSION).tar.bz2.sign

$(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2:  clean
	@echo "Did you update the version and changelog info in?:"
	@echo 
	@echo '# Scrape-n-paste'
	@echo 'vim VERSION ; ver=$$(cat VERSION)'
	@echo 
	@echo '# deb pkg bits first'
	@echo 'git log `git describe --tags --abbrev=0`..HEAD --oneline > /tmp/${package}.gitlog'
	@echo 'while read line; do dch --newversion $$ver "$$line"; done < /tmp/simple-state-manager.gitlog'
	@echo
	@echo '# RPM bits next'
	@echo 'perl -pi -e "s/^Version:.*/Version:      $$ver/" rpm/simple-state-manager.spec'
	@echo '# dont worry about changelog entries in spec file for now...  #vim rpm/simple-state-manager.spec'
	@echo
	@echo '# commit changes and go'
	@echo 'echo git commit -m "prep for v$$ver" -a'
	@echo 'echo git tag v$$ver'
	@echo 
	@echo "If 'yes', then hit <Enter> to continue..."; \
	read i
	mkdir -p    $(TOPDIR)/tmp/
	git clone . $(TOPDIR)/tmp/${package}-$(VERSION)/
	git log   > $(TOPDIR)/tmp/${package}-$(VERSION)/CHANGE.LOG
	rm -fr      $(TOPDIR)/tmp/${package}-$(VERSION)/.git
	rm -f       $(TOPDIR)/tmp/${package}-$(VERSION)/bin/ssm_web-report
	find  $(TOPDIR)/tmp/${package}-$(VERSION) -type f -exec chmod ug+r  {} \;
	find  $(TOPDIR)/tmp/${package}-$(VERSION) -type d -exec chmod ug+rx {} \;
	cd    $(TOPDIR)/tmp/ && tar -ch ${package}-$(VERSION) | bzip2 > ${package}-$(VERSION).tar.bz2
	ls -l $(TOPDIR)/tmp/

.PHONY: clean
clean:
	rm -fr $(TOPDIR)/tmp/
	rm -fr $(TOPDIR)/usr/share/man/

.PHONY: distclean
distclean: clean
	rm -f  $(TOPDIR)/configure-stamp
	rm -f  $(TOPDIR)/build-stamp
	rm -f  $(TOPDIR)/debian/files
	rm -fr $(TOPDIR)/debian/${package}/

