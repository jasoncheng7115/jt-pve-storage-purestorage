PACKAGE = jt-pve-storage-purestorage
VERSION = 1.0.0

DESTDIR =
PREFIX = /usr

PERL_MODULES = \
    lib/PVE/Storage/Custom/PureStoragePlugin.pm \
    lib/PVE/Storage/Custom/PureStorage/API.pm \
    lib/PVE/Storage/Custom/PureStorage/Naming.pm \
    lib/PVE/Storage/Custom/PureStorage/ISCSI.pm \
    lib/PVE/Storage/Custom/PureStorage/Multipath.pm \
    lib/PVE/Storage/Custom/PureStorage/FC.pm

.PHONY: all install clean test deb

all:
	@echo "Nothing to build. Run 'make install' or 'make deb'."

install:
	install -d $(DESTDIR)$(PREFIX)/share/perl5/PVE/Storage/Custom/
	install -d $(DESTDIR)$(PREFIX)/share/perl5/PVE/Storage/Custom/PureStorage/
	install -m 0644 lib/PVE/Storage/Custom/PureStoragePlugin.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/Storage/Custom/
	install -m 0644 lib/PVE/Storage/Custom/PureStorage/*.pm \
		$(DESTDIR)$(PREFIX)/share/perl5/PVE/Storage/Custom/PureStorage/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm
	rm -rf $(DESTDIR)$(PREFIX)/share/perl5/PVE/Storage/Custom/PureStorage/

test:
	@echo "Running Perl syntax checks..."
	@for f in $(PERL_MODULES); do \
		echo "Checking $$f..."; \
		perl -Ilib -c $$f || exit 1; \
	done
	@echo "All syntax checks passed."

clean:
	rm -rf debian/jt-pve-storage-purestorage/
	rm -rf debian/.debhelper/
	rm -f debian/debhelper-build-stamp
	rm -f debian/files
	rm -f debian/*.substvars
	rm -f debian/*.log
	rm -f ../*.deb ../*.changes ../*.buildinfo

deb:
	dpkg-buildpackage -us -uc -b

deb-clean: clean
	rm -f ../$(PACKAGE)_*.deb
	rm -f ../$(PACKAGE)_*.changes
	rm -f ../$(PACKAGE)_*.buildinfo
