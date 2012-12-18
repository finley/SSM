#  
#   Copyright (C) 2006-2008 Brian Elliott Finley
#
#   $Id: SimpleStateManager.pm 234 2008-10-16 02:06:06Z finley $
#    vi: set filetype=perl tw=0:
# 

package SimpleStateManager::None;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(   
                upgrade_ssm 
                get_pkgs_currently_installed
            );

use strict;
use SimpleStateManager qw(ssm_print run_cmd);


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager/None.pm | perl -pi -e 's/^sub /#   /; s/ {//;' | sort
#
#   get_pkgs_currently_installed
#   upgrade_ssm
#
#
################################################################################


################################################################################
#
#   Subroutines
#

sub upgrade_ssm {
    ssm_print ">>\n>> upgrade_ssm()\n" if( $main::o{debug} );
    return 1;
}

sub get_pkgs_currently_installed {
    ssm_print ">>\n>> get_pkgs_currently_installed()\n" if( $main::o{debug} );

    # Technically, returning undef here, or just letting it happen
    # later, would work -- based on current checking done by the
    # rest of the code.  But we don't want to trust ourselves, see.
    # Not in the future.  So, we are at least returning a hash --
    # just an empty one. -BEF-
    return my %hash;
}

#
################################################################################

1;

