#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  grep-log.pl
#
#        USAGE:  ./grep-log.pl
#
#  DESCRIPTION:
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  YOUR NAME (),
#      COMPANY:
#      VERSION:  1.0
#      CREATED:  07/03/2011 08:05:28 AM
#     REVISION:  ---
#===============================================================================

use utf8;
use strict;
use warnings;
use 5.12.0;

while (<>) {
	state $route;
	state $warned = {};
	$route = $1 if (m/Processing route: (.*)/);
	if( m/Missing stop: <.*> => <(.*)>/) {
		say "Missing?: $route $1" unless $warned->{$route}->{$1};
		$warned->{$route}->{$1} = 1;
	}
	if( m/Failed to find closest stop<>way for <.*> <(.*)>/) {
		say "Closest?: $route $1" unless $warned->{$route}->{$1};
		$warned->{$route}->{$1} = 1;
	}
}
