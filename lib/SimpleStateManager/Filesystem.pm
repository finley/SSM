#  
#   Copyright (C) 2015-2016 Brian Elliott Finley
#
#    vi: set et ai ts=4 filetype=perl tw=0 number:
# 

package SimpleStateManager::Filesystem;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
                get_file_timestamp
                normalized_file_name
            );
use strict;
use SimpleStateManager qw(ssm_print run_cmd);
use File::Copy;
use File::Path;
use File::Basename;
use Unix::Mknod qw(:all);
use File::stat qw(:FIELDS);
#
# The POSIX library (with qw(mkfifo)) is exporting the S_IS* functions, so we
# need to limit which functions Fcntl exports by explicitly listing the ones
# we need. -BEF-
use POSIX qw(mkfifo);
use Fcntl qw( :mode );
use Digest::MD5;
use Cwd 'abs_path';


################################################################################
#
#   This package provides the following functions:
#
#       $ egrep '^sub ' lib/SimpleStateManager/FilesystemeDpkgpm | perl -p -e 's/^sub /#   /; s/ {//;' | sort
#
#   get_file_timestamp
#   normalized_file_name
#
################################################################################

################################################################################
#
#   BEGIN subroutines
#

#
#   my $timestamp = get_file_timestamp($file); (returns an epoch style
#   timestamp)
#
sub get_file_timestamp {

    my $file = shift;
    
    if( ! -e $file ) {
        return undef;
    } else {
        return stat($file)->mtime;
    }
}


sub normalized_file_name {
    
    my $file = shift;

    # Turn double slashes into single slashes so that tests for conflicting
    # host names work properly.
    $file =~ s|/+|/|go;

    # Turn directories specified with an ending slash into no ending slash to
    # ensure conflicting directory names are treated properly.
    $file =~ s|/$||o;

    return $file;
}

#
#   END subroutines
#
################################################################################


1;

