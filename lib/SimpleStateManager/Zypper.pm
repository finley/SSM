#  
#   Copyright (C) 2006-2017 Brian Elliott Finley
#
#    vi: set et ai ts=4 filetype=perl tw=0 number:
# 

package SimpleStateManager::Zypper;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
                autoremove_pkgs
                do_pkg_manager_dry_run
                get_pending_pkg_changes
                get_pkgs_provided_by_pkgs_from_state_definition
                get_pkgs_currently_installed
                get_pkg_dependencies
                get_pkg_reverse_dependencies
                get_pkg_repo_update_time_stamp
                get_running_kernel_pkg_name
                install_pkgs
                remove_pkgs
                update_pkg_availability_data
                upgrade_pkgs
                verify_pkgs_exist
            );

use strict;
use XML::LibXML;
use SimpleStateManager qw(ssm_print run_cmd choose_tmp_file);
use SimpleStateManager::Filesystem qw(get_file_timestamp);


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager/Zypper.pm | perl -pi -e 's/^sub /#   /; s/ {//;' | sort
#
#   autoremove_pkgs
#   do_pkg_manager_dry_run
#   download_pkgs
#   get_basearch
#   get_pending_pkg_changes
#   get_pkg_repo_update_time_stamp
#   get_pkgs_currently_installed
#   get_pkgs_provided_by_pkgs_from_state_definition
#   get_running_kernel_pkg_name
#   install_pkgs
#   remove_pkgs
#   update_pkg_availability_data
#   upgrade_pkgs
#
################################################################################


################################################################################
#
#   Subroutines
#

#
#   Usage:  my %hash = do_pkg_manager_dry_run($action, $space_delimited_pkg_list);
#   Usage:  my %hash = do_pkg_manager_dry_run("install", "ash sendmail rsync");
#   Usage:  my %hash = do_pkg_manager_dry_run("remove", "ash sendmail rsync");
#   Usage:  my %hash = do_pkg_manager_dry_run("upgrade");
#   Usage:  my %hash = do_pkg_manager_dry_run("autoremove");
#
#       Returns a hash of $pkg = $pending_state;
#       Where $pending_state may be one of 'install', 'upgrade', 'dist-upgrade', 'autoremove, or 'remove'.
#
sub do_pkg_manager_dry_run {

    my $action                   = shift;
    my $space_delimited_pkg_list = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pending_pkg_changes;

    if(! $space_delimited_pkg_list) {
        if($action eq 'upgrade' or $action eq 'dist-upgrade') {
            #
            # make sure we have some value in this variable to feed the
            # function below...
            $space_delimited_pkg_list = "";

        } else {
            return %pending_pkg_changes;
        }
    }

    #
    #   XML::LibXML reference:  
    #       http://grantm.github.io/perl-libxml-by-example/basics.html
    #
    #
    #   Example data:
    #
    # list-updates: /stream/update-status/update-list/update
    #   /stream/update-status/update-list/update
    #       <update name="Mesa" edition="10.0.2-100.1" arch="x86_64" kind="package">[otherstuff...]</update>
    #       <update name="Mesa-libEGL1" edition="10.0.2-100.1" arch="x86_64" kind="package">[otherstuff...]</update>
    #
    # install:
    #   /stream/install-summary/to-install/solvable
    #       <solvable type="package" name="apache2" edition="2.4.16-19.1" arch="x86_64" summary="The Apache Web Server Version 2.4">
    #       <solvable type="package" name="apache2-prefork" edition="2.4.16-19.1" arch="x86_64" summary="Apache 2 "prefork" MPM (Multi-Processing Module)">
    #
    # remove:       
    #   /stream/install-summary/to-upgrade/solvable
    #       <solvable type="package" name="libgudev-1_0-0"  edition="210-116.6.6" arch="x86_64" edition-old="210-83.2" arch-old="x86_64" summary="GObject library, to access udev device information">
    #       <solvable type="package" name="libudev1"        edition="210-116.6.6" arch="x86_64" edition-old="210-83.2" arch-old="x86_64" summary="Dynamic library to access udev device information">
    #   /stream/install-summary/to-remove/solvable
    #       <solvable type="package" name="aaa_base"        edition="13.2+git20140911.61c1681-9.1" arch="x86_64" summary="openSUSE Base Package">
    #       <solvable type="package" name="aaa_base-extras" edition="13.2+git20140911.61c1681-9.1" arch="x86_64" summary="SUSE Linux Base Package (recommended part)">
    #
    #   /stream/update-status/update-list/update
    #   /stream/install-summary/to-install/solvable
    #   /stream/install-summary/to-upgrade/solvable
    #   /stream/install-summary/to-remove/solvable

    my $cmd;
    my $nodes_location;
    if($action eq 'upgrade') {
        $cmd = 'zypper --non-interactive --xmlout update --dry-run';
    }
    if($action eq 'autoremove') {
        #$cmd = "zypper --non-interactive --xmlout remove       --dry-run --clean-deps $space_delimited_pkg_list";
        $cmd = "/bin/true"; #XXX skip this feature for now w/Zypper.  Looks like it needs to run _with_ a package name.
    }
    elsif($action eq 'install') {
        $cmd = "zypper --non-interactive --xmlout install --dry-run $space_delimited_pkg_list";
    }
    elsif($action eq 'remove') {
        $cmd = "zypper --non-interactive --xmlout remove  --dry-run";
        $cmd .= " --clean-deps"  if($::o{pkg_manager_autoremove} and $::o{pkg_manager_autoremove} eq 'yes');
        $cmd .= " $space_delimited_pkg_list";
    }

    open my $fh, "$cmd|";
    binmode $fh, ':raw';
    my $dom = XML::LibXML->load_xml(IO => $fh);

    foreach my $node_root ( 'upgrade', 'install', 'remove' ) {

        my $node_root = "/stream/install-summary/to-${action}/solvable";
        foreach my $entry ($dom->findnodes($node_root)) {

            next unless ((defined $entry->{'kind'} and $entry->{'kind'} eq 'package') 	# update-list style
                      or (defined $entry->{'type'} and $entry->{'type'} eq 'package'));	# all other stylishnesses

            my $pkg                                     = $entry->{'name'};
            $pending_pkg_changes{$pkg}{target_version}  = $entry->{'edition'};
            $pending_pkg_changes{$pkg}{current_version} = $entry->{'edition-old'};
            $pending_pkg_changes{$pkg}{action}          = $action;

            #print "$action  $pkg  T: $target_version";
            #print " C: $current_version" if($current_version);
            #print "\n";
        }   
    }   

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pending_pkg_changes;
}


#
#   my %pending_pkg_changes = get_pending_pkg_changes($action);
#   
#       Where $action is one of 'install', 'remove', or 'upgrade'.
#
sub get_pending_pkg_changes {

    my $action = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_already_installed = get_pkgs_currently_installed();

    my $basearch = get_basearch();

    my %space_delimited_pkg_list;
    my %pending_pkg_changes;

    if($action eq 'upgrade') {
        %pending_pkg_changes = do_pkg_manager_dry_run($action);

    } elsif($action eq 'autoremove') {

        #
        # Zypper supports "autoremove" as the --clean-deps option, but must be
        # used along with the removal of a package.  Look for this as
        # augmenting the remove options.
        #

        # packages cannot begin with a hyphen, so just pass the response back in this way
        $pending_pkg_changes{'-autoremove_unsupported'} = 1;

        return %pending_pkg_changes;

    } else {

        foreach my $pkg (keys %::PKGS_FROM_STATE_DEFINITION) {

            my $options = $::PKGS_FROM_STATE_DEFINITION{$pkg};

            if($options =~ m/\b(unwanted|remove|delete|erase)\b/i) {

                $space_delimited_pkg_list{'remove'}  .= " $pkg" if($pkgs_already_installed{"$pkg.$basearch"});
                $space_delimited_pkg_list{'remove'}  .= " $pkg" if($pkgs_already_installed{"$pkg.noarch"});

            } else {

                #
                # If the package is already installed, no need to try and install it
                # again, so skip it.
                #
                next if( $pkgs_already_installed{"$pkg.$basearch"} );
                next if( $pkgs_already_installed{"$pkg.noarch"} );
                next if( $pkgs_already_installed{"$pkg"} );

                $space_delimited_pkg_list{'install'}  .= " $pkg";
            }
        }

        %pending_pkg_changes = do_pkg_manager_dry_run($action, $space_delimited_pkg_list{$action});
    }

    #
    # Help user to make sure they don't try to remove something they want to keep
    #
    foreach my $pkg (sort keys %pending_pkg_changes) {

        if( $pending_pkg_changes{$pkg} eq 'remove' ) {

            if ($::PKGS_TARGET_STATE{$pkg} and ($::PKGS_TARGET_STATE{$pkg} ne 'remove')) {
                ssm_print "WARNING: Package $pkg is now marked as $pending_pkg_changes{$pkg}, but was already marked as $::PKGS_TARGET_STATE{$pkg}\n";

            } elsif ($::PKGS_FROM_STATE_DEFINITION{$pkg} and $::PKGS_FROM_STATE_DEFINITION{$pkg} !~ m/\b(unwanted|remove|delete|erase)\b/i) {
                ssm_print "WARNING: Package $pkg is now marked as $pending_pkg_changes{$pkg}, but is marked for install in the config.\n";
            }

        } else {
            $::PKGS_TARGET_STATE{$pkg} = $pending_pkg_changes{$pkg};
        }
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pending_pkg_changes;
}


#
# Usage: my $basearch = get_basearch();
#
sub get_basearch {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

	use POSIX;
	
	my $basearch = (uname())[4];
	$basearch =~ s/i.86/i386/;

    ssm_print "$debug_prefix $basearch\n" if( $::o{debug} );

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return $basearch;
}


sub update_pkg_availability_data {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $::o{no_pkg_repo_update} ) {
        ssm_print "INFO:    Not updating package repo info\n" unless($::o{not_ok});
        return 1;
    }

    #
    # Get the latest updates
    my $cmd = 'zypper --non-interactive refresh >/dev/null';
    #
    # Run even if --no so that we don't get 'Unable to locate package X'
    # errors. -BEF-
    run_cmd($cmd, undef, 1);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return 1;
}

sub remove_pkgs {
    ssm_print ">>\n>> remove_pkgs()\n" if( $::o{debug} );

    my @packages = @_;

    my $cmd = "zypper --non-interactive remove";
    $cmd .= " --clean-deps" if($::o{pkg_manager_autoremove} and $::o{pkg_manager_autoremove} eq 'yes');
    foreach my $pkg (@packages) {
        $cmd .= " $pkg";
    }

    ssm_print ">> $cmd\n" if( $::o{debug} );
    ssm_print "FIXING:  Packages -> Removing.\n";
    run_cmd($cmd);

    return 1;
}


sub upgrade_pkgs {
    ssm_print ">>\n>> upgrade_pkgs()\n" if( $::o{debug} );

    my @packages = @_;

    if(scalar(@packages) eq 0) { return 1; }

    ssm_print "FIXING:  Packages -> Upgrading.\n";
    my $cmd = "zypper --non-interactive update --auto-agree-with-licenses @packages";
    ssm_print ">>   $cmd\n" if( $::o{debug} );
    run_cmd($cmd);

    return 1;    
}


sub install_pkgs {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @packages = @_;

    if(scalar(@packages) eq 0) { return 1; }

    ssm_print "FIXING:  Packages -> Installing.\n";
    my $cmd = "zypper --non-interactive install --auto-agree-with-licenses @packages";
    ssm_print "$debug_prefix $cmd\n" if( $::o{debug} );
    run_cmd($cmd);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return 1;    
}


#
# returns a hash of:   $package.$basearch => $version
#
sub get_pkgs_currently_installed {
    
    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_currently_installed;

    my $cmd = 'zypper --non-interactive --xmlout packages --installed-only';
    ssm_print "$debug_prefix system($cmd)\n" if( $::o{debug} );
    open(FILE,"$cmd|") or die("couldn't open $cmd for reading");
    while (<FILE>) {
    
        # Sample output:
        #
        # i | SLES12-SP1-12.1-0   | yast2-xml                            | 3.1.1-1.46                   | x86_64
        # i | SLES12-SP1-12.1-0   | yast2-ycp-ui-bindings                | 3.1.9-1.6                    | x86_64
        # i | SLES12-SP1-12.1-0   | yelp                                 | 3.10.2-1.20                  | x86_64
        # i | SLES12-SP1-12.1-0   | yelp-lang                            | 3.10.2-1.20                  | noarch
        # i | SLES12-SP1-12.1-0   | yelp-xsl                             | 3.10.1-1.5                   | noarch
        # i | SLES12-SP1-12.1-0   | yp-tools                             | 2.14-6.1                     | x86_64
        # i | SLES12-SP1-12.1-0   | ypbind                               | 1.37.2-3.6                   | x86_64
        # i | SLES12-SP1-12.1-0   | zenity                               | 3.10.2-1.25                  | x86_64
        # i | SLES12-SP1-12.1-0   | zenity-lang                          | 3.10.2-1.25                  | noarch
        # i | SLES12-SP1-12.1-0   | zip                                  | 3.0-15.18                    | x86_64
        # i | SLES12-SP1-12.1-0   | zisofs-tools                         | 1.0.8-20.61                  | x86_64
        # i | SLES12-SP1-12.1-0   | zsh                                  | 5.0.5-4.63                   | x86_64
        # i | SLES12-SP1-12.1-0   | zypp-plugin-python                   | 0.5-1.1                      | x86_64
        # i | SLES12-SP1-12.1-0   | zypper                               | 1.12.23-1.3                  | x86_64
        # i | SLES12-SP1-12.1-0   | zypper-log                           | 1.12.23-1.3                  | noarch

        if( m/^i \| .* \| (\S+)\s+\| (\S+)\s+\| (\S+)/ ) {

            my $pkg         = $1;
            my $version     = $2;
            my $pkg_arch    = $3;

            $pkgs_currently_installed{"$pkg.$pkg_arch"} = $version; # allows testing for existence of "package.arch"
            $pkgs_currently_installed{$pkg}{$pkg_arch} = $version;  # allows testing for existence of "package", but arch is still discernable

            ssm_print "$debug_prefix PKG $pkg.$pkg_arch = $version\n" if( $::o{debug} );
        }
    }
    close(FILE);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pkgs_currently_installed;
}


sub get_pkgs_provided_by_pkgs_from_state_definition {
    ssm_print ">>\n>> get_pkgs_provided_by_pkgs_from_state_definition()\n" if( $::o{debug} );

    my $PKGS_FROM_STATE_DEFINITION = shift;
    return %$PKGS_FROM_STATE_DEFINITION;
}


sub get_running_kernel_pkg_name {

    use POSIX;
    my $release = (uname())[2];

    my $running_kernel_pkg_name = `rpm -qf /lib/modules/${release}/kernel`;
    chomp $running_kernel_pkg_name;
    $running_kernel_pkg_name =~ s/:.*//;

    return $running_kernel_pkg_name;
}


sub autoremove_pkgs {

    my @pkgs = @_;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    return remove_pkgs(@pkgs);
}


sub get_pkg_repo_update_time_stamp {

    my $dir = '/var/cache/zypp/raw/';

    my $timestamp = get_file_timestamp( $dir );

    return $timestamp;
}


#
# Usage:  verify_pkgs_exist( @packages );
#
sub verify_pkgs_exist {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @packages = @_;
    my $return_code = 1;

    foreach my $pkg (@packages) {
        my $cmd = "zypper --non-interactive --xmlout search $pkg";
        open my $fh, "$cmd|";
        binmode $fh, ':raw';
        my $dom = XML::LibXML->load_xml(IO => $fh);
print "Monkey!!!\n"; exit 99;
        my $node_root = "/stream/solvable-list/to-XXXX/solvable";
        foreach my $entry ($dom->findnodes($node_root)) {
        }

        if( "it exists" ) {
            ssm_print "AddPkg:  $pkg NOT available.\n";
            $return_code++;
        } else {
            ssm_print "AddPkg:  $pkg is available.\n";
        }
    }

    return $return_code;
}


#
################################################################################


1;

