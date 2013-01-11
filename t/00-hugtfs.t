#!/usr/bin/perl

use 5.10.0;
use strict;
use warnings;

BEGIN {
	use Test::More tests => 9;
}

BEGIN { use_ok("Cal"); }
BEGIN { use_ok("HuGTFS"); }
BEGIN { use_ok("HuGTFS::Crawler"); }
BEGIN { use_ok("HuGTFS::OSMMerger"); }
BEGIN { use_ok("HuGTFS::FeedManager"); }
BEGIN { use_ok("HuGTFS::Dumper"); }
BEGIN { use_ok("HuGTFS::KML"); }
BEGIN { use_ok("HuGTFS::SVG"); }
BEGIN { use_ok("HuGTFS::Util"); }
