=head1 NAME

HuGTFS::Dumper - Utility methods for helping test HuGTFS.

=head1 SYNOPSIS

	use HuGTFS::Dumper;
	
=head1 REQUIRES

perl 5.14.0

=head1 DESCRIPTION

Simple test methods for assisting the testing of HuGTFS.

=head1 METHODS
					
=cut

package HuGTFS::Test;

use 5.14.0;
use utf8;
use strict;
use warnings;

use Test::More;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(is_active is_inactive);

my $builder = Test::More->builder;
binmode $builder->output,         ":utf8";
binmode $builder->failure_output, ":utf8";
binmode $builder->todo_output,    ":utf8";

=head2 is_active $servce, $date, $name

Is the service active on the specified date?

=cut

sub is_active($$$)
{
	my ( $service, $date, $name ) = @_;
	if ( !ref $service ) {
		$service = Cal->find($service);
	}

	unless ( $service && $service->isa('Cal') ) {
		fail($name);
		diag("Service $service doesn't exist");
		return 0;
	}

	ok( $service->enabled($date), $name ) or diag("Service " . $service->service_id . " is inactive on $date");
}

=head2 is_inactive $servce, $date, $name

Is the service inactive on the specified date?

=cut

sub is_inactive($$$)
{
	my ( $service, $date, $name ) = @_;
	if ( !ref $service ) {
		$service = Cal->find($service);
	}

	unless ( $service && $service->isa('Cal') ) {
		fail($name);
		diag("Service $service doesn't exist");
		return 0;
	}

	ok( !$service->enabled($date), $name ) or diag("Service " . $service->service_id . " is active on $date");
}

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
