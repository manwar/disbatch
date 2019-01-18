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
