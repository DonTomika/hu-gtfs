#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  a.pl
#
#        USAGE:  ./a.pl  
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
#      CREATED:  07/02/2011 02:23:14 PM
#     REVISION:  ---
#===============================================================================

use utf8;
use 5.12.0;

binmode(STDOUT, ':utf8');
binmode(STDIN,  ':utf8');

my ($file, $routes, $rels);

open( $file, "tmp/routes.txt" );
binmode($file, ':utf8');
for(<$file>) {
	my ($id, $route, $name, $type) = ($_ =~ m/^(.*?),.*?,(.*?),.*?,"(.*?)",(\d)/);
	$routes->{$route} = $name if $id =~ m/^9/;
}

open( $file, "bkv/bp-all.osm");
binmode($file, ':utf8');
foreach my $line (<$file>) {
	state $state = 0;
	state ($rel_id, $tags);

	if($line =~ m/<relation id='(.*?)'/) {
		$rel_id = $1;
		$tags = {};
	}
	if($rel_id && $line =~ m{</relation}) {
		if($tags->{type} eq 'line' && $routes->{$tags->{ref}}) {
			$rels->{$tags->{ref}} = $rel_id;
		}
		$rel_id = undef;
	}
	if($rel_id && $line =~ m{<tag k='(.*)' v='(.*)'}) {
		$tags->{$1} = $2;
	}
}

print <<EOF;
{| border="1" cellpadding="4" cellspacing="0" style="margin: 1em 1em 1em 0; background: #f9f9f9; border: 1px #aaa solid; border-collapse: collapse; font-size: 95%;"
|- style="background-color:#E9E9E9"
!|Szám
!|Megtekintés
!style="width:70px"|Állapot
!|Felülvizsgálta
!|Megjegyzés
|-
EOF

for(sort { $a <=> $b || $a cmp $b } keys %$routes) {
	my $lc = lc $_;
	my $rel = $rels->{$_} ? "{{HU:Relation|$rels->{$_}}}" : '';
	$routes->{$_} =~ s/^(.*) \/ (.*)$/'''$1''' - '''$2'''/;
	print <<EOF;
|'''[http://www.bkv.hu/ejszakai/$lc.html $_]''' ([http://www.bkv.hu/ejszakai/${lc}vissza.html vissza])
|$rel
|{{HU:RouteStatus|Bus|0|0}}
|
|$routes->{$_}
|-
EOF
}
print <<EOF;
|}
EOF
