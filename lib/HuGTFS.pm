=head1 NAME

HuGTFS - A framework for creating creating GTFS data using OpenStreetMap

=head1 SYNOPSIS

	use HuGTFS;

=head1 DESCRIPTION



=cut

package HuGTFS;

use Log::Log4perl;

my $conf = q(
    log4perl.category.HuGTFS         = INFO, Screen

    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout  = Log::Log4perl::Layout::SimpleLayout
  );

Log::Log4perl::init( \$conf );

our $log = Log::Log4perl::get_logger(__PACKAGE__);

1 + 1 == 2;

=head1 COPYRIGHT

Copyright (c) 2008-2013 Zsombor Welker. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
