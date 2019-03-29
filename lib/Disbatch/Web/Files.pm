package Disbatch::Web::Files;

use 5.12.0;
use warnings;

use Limper::SendFile;
use Limper;

get '/' => sub {
    send_file '/index.html';
};


get qr{^/} => sub {
    send_file request->{path};        # sends request->{uri} by default
};


1;

=head1 AUTHORS

Ashley Willis <awillis@synacor.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2016, 2019 by Ashley Willis.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004
