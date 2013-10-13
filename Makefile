#
# $Id: Makefile 376 2010-09-01 17:25:40Z finley $
#  vi:set filetype=make noet ai:
#

SHELL = /bin/sh

#
# These settings are what I would expect for most modern Linux distros, 
# and are what work for me unmodified on Ubuntu. -BEF-
# 
package		= ssm
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

.PHONY: install
install:  all
	test -d ${sysconfdir} || install -d -m 755 ${sysconfdir}
	test -e ${sysconfdir}/client.conf || install -m 644 etc/client.conf	${sysconfdir}
	
	test -d ${bindir} || install -d -m 755 ${bindir}
	install -m 755 bin/ssm 					${bindir}
	install -m 755 bin/ssm_add-file 		${bindir}
	install -m 755 bin/ssm_web-report 		${bindir}
	
	@test ! -e ${bindir}/system-state-manager || \
		(echo; echo; \
		echo "WARNING: Please remove old binary -> \"sudo rm ${bindir}/system-state-manager\""; \
		echo; echo; \
		echo "Hit <Enter> to continue..."; \
		read i)
	
	test -d ${libdir} || install -d -m 755 ${libdir}
	install -m 644 $(TOPDIR)/tmp/lib/SimpleStateManager.pm ${libdir}/SimpleStateManager.pm
	
	test -d ${libdir}/SimpleStateManager/ || install -d -m 755 ${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/Aptitude.pm ${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/Dpkg.pm 	${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/Yum.pm  	${libdir}/SimpleStateManager/
	install -m 644 $(TOPDIR)/lib/SimpleStateManager/None.pm  	${libdir}/SimpleStateManager/
	
	test -d ${docdir} || install -d -m 755 ${docdir}
	rsync -av --exclude '.*' usr/share/doc/ ${docdir}
	install -m 644 $(TOPDIR)/CREDITS  	${docdir}
	install -m 644 $(TOPDIR)/COPYING  	${docdir}
	install -m 644 $(TOPDIR)/README  	${docdir}
	cd ${docdir} && /bin/ln -sf README ${docdir}/examples/one-of-each.conf
	find ${docdir} -type d -exec chmod 0775 '{}' \;
	find ${docdir} -type f -exec chmod 0664 '{}' \;

#	test -d ${mandir}/man1 || install -d -m 755 ${mandir}/man1
#	install -m 644 wifi-radar.1 		${mandir}/man1
#	
#	test -d ${mandir}/man5 || install -d -m 755 ${mandir}/man5
#	install -m 644 wifi-radar.conf.5 	${mandir}/man5
	

.PHONY: release
release:  tarball debs rpms
	@echo 
	@echo "I'm about to upload the following files to:"
	@echo "  ~/src/www.systemimager.org/pub/ssm/"
	@echo "-----------------------------------------------------------------------"
	@/bin/ls -1 $(TOPDIR)/tmp/latest.*
	@/bin/ls -1 $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.*
	@/bin/ls -1 $(TOPDIR)/tmp/${package}[-_]latest*.*
	@/bin/ls -1 ${rpmbuild}/RPMS/*/ssm-$(VERSION)-*.rpm 
	@/bin/ls -1 ${rpmbuild}/SRPMS/ssm-$(VERSION)-*.rpm
	@echo
	@echo "Hit <Enter> to continue..."
	@read i
	#rsync -av --progress $(TOPDIR)/tmp/latest.* $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.* ${rpmbuild}/RPMS/*/ssm-$(VERSION)-*.rpm ${rpmbuild}/SRPMS/ssm-$(VERSION)-*.rpm web.sourceforge.net:/home/project-web/systemimager/htdocs/pub/ssm/
	rsync -av --progress $(TOPDIR)/tmp/latest.* $(TOPDIR)/tmp/${package}[-_]$(VERSION)*.* $(TOPDIR)/tmp/${package}[-_]latest*.* ${rpmbuild}/RPMS/*/ssm-$(VERSION)-*.rpm ${rpmbuild}/SRPMS/ssm-$(VERSION)-*.rpm ~/src/www.systemimager.org/pub/ssm/
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
	sudo rpmbuild -ta $(TOPDIR)/tmp/${package}-$(VERSION).tar.gz
	cd $(TOPDIR)/tmp && ln -s ${package}-$(VERSION)-1.noarch.rpm ${package}-latest.noarch.rpm

.PHONY: deb
deb:  debs

.PHONY: debs
debs:  tarball
	cd $(TOPDIR)/tmp/${package}-$(VERSION) \
		&& fakeroot dpkg-buildpackage -uc -us
	cd $(TOPDIR)/tmp && ln -s ${package}_$(VERSION)-1ubuntu1_all.deb ${package}_latest_all.deb

.PHONY: tarball
tarball:  $(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2.sign
$(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2.sign: $(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2
	cd $(TOPDIR)/tmp && gpg --detach-sign -a --output ${package}-$(VERSION).tar.bz2.sign ${package}-$(VERSION).tar.bz2
	cd $(TOPDIR)/tmp && gpg --verify ${package}-$(VERSION).tar.bz2.sign
	cd $(TOPDIR)/tmp && ln -s ${package}-$(VERSION).tar.bz2 latest.tar.bz2
	cd $(TOPDIR)/tmp && ln -s ${package}-$(VERSION).tar.bz2.sign latest.tar.bz2.sign

$(TOPDIR)/tmp/${package}-$(VERSION).tar.bz2:  clean
	@echo "Did you update the version and changelog info in?:"
	@echo "	* VERSION"
	@echo "	* debian/changelog (can use 'dch -i')"
	@echo "	* rpm/ssm.spec"
	@echo "If 'yes', then hit <Enter> to continue..."; \
	read i
	mkdir -p $(TOPDIR)/tmp/
	rsync -a . $(TOPDIR)/tmp/${package}-$(VERSION)/
	rm -fr $(TOPDIR)/tmp/${package}-$(VERSION)/.git
	git log > $(TOPDIR)/tmp/${package}-$(VERSION)/CHANGE.LOG
	find $(TOPDIR)/tmp/${package}-$(VERSION) -type f -exec chmod ug+r  {} \;
	find $(TOPDIR)/tmp/${package}-$(VERSION) -type d -exec chmod ug+rx {} \;
	cd $(TOPDIR)/tmp && tar -ch ${package}-$(VERSION) | bzip2 > ${package}-$(VERSION).tar.bz2
	ls -l $(TOPDIR)/tmp/

.PHONY: clean
clean:
	rm -fr $(TOPDIR)/tmp/

.PHONY: distclean
distclean: clean
	rm -f  $(TOPDIR)/configure-stamp
	rm -f  $(TOPDIR)/build-stamp
	rm -f  $(TOPDIR)/debian/files
	rm -fr $(TOPDIR)/debian/ssm/

