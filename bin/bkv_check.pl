#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  bkv_check.pl
#
#        USAGE:  ./bkv_check.pl
#
#  DESCRIPTION:  Check if the timetables changed in the last 24 hours; if it has, then
#                send a summary of  the changes
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Zsombor Welker (flaktack), flaktack@welker.hu
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  05/13/2010 10:51:37 AM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;

use MIME::Lite;

my $email = <<EOF;
Szia!

Az alabbi menetrendek modosultak:
EOF

# Find current dir
my $bkv_dir = $ARGV[0];
my ( $current, $last, $ctime, $ltime ) = ( undef, undef, 0, 0 );

chdir($bkv_dir);

opendir( my $dir, $bkv_dir );
for ( readdir $dir ) {
	if ( $_ ne '.' && $_ ne '..' && -d $_ && !-l $_ ) {
		if ( ( stat $_ )[9] > $ctime ) {
			$last    = $current;
			$ltime   = $ctime;
			$current = $_;
			$ctime   = ( stat $_ )[9];
		}
		elsif ( ( stat $_ )[9] > $ltime ) {
			$last  = $_;
			$ltime = ( stat $_ )[9];
		}
	}
}
closedir($dir);

# Go through dirs

unless ( $current && $last ) {
	exit 1;
}

unless ( time - $ctime < 18 * 60 * 60 ) {
	exit 0;
}

$email .= "(" . localtime($ltime) . " => " . localtime($ctime) . ")\n\n";

my $found = 0;

opendir( $dir, $current );
for my $file ( sort readdir $dir ) {
	next if $file eq 'map.txt';

	if ( ( stat "$current/$file" )[9] - $ltime > 0 && $file !~ m/^\.\.?$/ ) {
		$found = 1;
		$email
			.= "$file\n\t"
			. localtime( ( stat "$current/$file" )[9] )
			. "\n\t$ARGV[1]/$current/$file\n";
		if ( -f "$last/$file" ) {
			$email
				.= "\n\t"
				. localtime( ( stat "$last/$file" )[9] )
				. "\n\t$ARGV[1]/$last/$file\n";
		}
		$email .= "\n";
	}
}
closedir($dir);

exit 0 unless $found;

my $msg = MIME::Lite->new(
	From    => 'noreply@flaktack.net',
	To      => 'flaktack@welker.hu',
	Cc      => 'mezei.gyula@alterbmv.hu',
	Subject => 'BKV menetrend modositasok',
	Type    => 'multipart/mixed'
);

my $part = MIME::Lite->new(
	Type => 'TEXT',
	Data => $email,
);
$part->attr( 'content-type.charset' => 'UTF-8' );

$msg->attach($part);

#$msg->print( \*STDOUT );
$msg->send;

exit 0;
