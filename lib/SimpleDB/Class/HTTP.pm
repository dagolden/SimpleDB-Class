package SimpleDB::Class::HTTP;

=head1 NAME

SimpleDB::Class::HTTP - The network interface to the SimpleDB service.

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

The following methods are available from this class.

=cut

use Moose;
use Digest::SHA qw(hmac_sha256_base64);
use XML::Simple;
use AnyEvent::HTTP;
use URI::Escape qw(uri_escape_utf8);
use SimpleDB::Class::Exception;

#--------------------------------------------------------

=head2 new ( params ) 

=head3 params

A hash containing the parameters to pass in to this method.

=head4 access_key

The access key given to you from Amazon when you sign up for the SimpleDB service at this URL: L<http://aws.amazon.com/simpledb/>

=head4 secret_key

The secret access key given to you from Amazon.

=cut

#--------------------------------------------------------

=head2 access_key ( )

Returns the access key passed to the constructor.

=cut

has 'access_key' => (
    is              => 'ro',
    required        => 1,
    documentation   => 'The AWS SimpleDB access key id provided by Amazon.',
);

#--------------------------------------------------------

=head2 secret_key ( )

Returns the secret key passed to the constructor.

=cut

has 'secret_key' => (
    is              => 'ro',
    required        => 1,
    documentation   => 'The AWS SimpleDB secret access key id provided by Amazon.',
);

#--------------------------------------------------------

=head2 construct_request ( action, [ params ] )

Returns a string that contains the HTTP post data ready to make a request to SimpleDB. Normally this is only called by send_request(), but if you want to debug a SimpleDB interaction, then having access to this method is critical.

=head3 action

The action to perform on SimpleDB. See the "Operations" section of the guide located at L<<a href="http://docs.amazonwebservices.com/AmazonSimpleDB/2009-04-15/DeveloperGuide/">http://docs.amazonwebservices.com/AmazonSimpleDB/2009-04-15/DeveloperGuide/</a>>.

=head3 params

Any extra prameters required by the operation. The normal parameters of Action, AWSAccessKeyId, Version, Timestamp, SignatureMethod, SignatureVersion, and Signature are all automatically provided by this method.

=cut

sub construct_request {
    my ($self, $action, $params) = @_;
    my $encoding_pattern = "^A-Za-z0-9\-_.~";

    # add required parameters
    $params->{'Action'}           = $action;
    $params->{'AWSAccessKeyId'}   = $self->access_key;
    $params->{'Version'}          = '2009-04-15';
    $params->{'Timestamp'}        = sprintf("%04d-%02d-%02dT%02d:%02d:%02d.000Z", sub { ($_[5]+1900, $_[4]+1, $_[3], $_[2], $_[1], $_[0]) }->(gmtime(time)));
    $params->{'SignatureMethod'}  = 'HmacSHA256';
    $params->{'SignatureVersion'} = 2;

    # construct post data
    my $post_data;
    foreach my $name (sort {$a cmp $b} keys %{$params}) {
        $post_data .= $name . '=' . uri_escape_utf8($params->{$name}, $encoding_pattern) . '&';
    }
    chop $post_data;

    # sign the post data
    my $signature = "POST\nsdb.amazonaws.com\n/\n". $post_data;
    $signature = hmac_sha256_base64($signature, $self->secret_key) . '=';
    $post_data .= '&Signature=' . uri_escape_utf8($signature, $encoding_pattern);

    return $post_data;
}

#--------------------------------------------------------

=head2 send_request ( action, [ params ] )

Creates a request, and then sends it to SimpleDB. The response is returned as a hash reference of the raw XML document returned by SimpleDB. Automatically attempts 5 cascading retries on connection failure.

=head3 action

See create_request() for details.

=head3 params

See create_request() for details.

=cut

sub send_request {
    my ($self, $action, $params) = @_;
    my $retries = 1;
    while (1) { # loop til we get a response or throw an exception
        my $response_returned = AnyEvent->condvar;
        http_post('https://sdb.amazonaws.com/',
            $self->construct_request($action, $params),
            timeout     => 30,
            headers     => {
                'Content-Type'  => 'application/x-www-form-urlencoded; charset=utf-8',
            },
            sub { $response_returned->send(@_); } 
        );
        my ($body, $headers) = $response_returned->recv;
        my $content = eval {XML::Simple::XMLin($body)};
        if ($@) {
            SimpleDB::Class::Exception::Response->throw(
                error       => 'Response was garbage. Are you sure you installed Net::SSLeay?', 
                status_code => $headers->{Status},
                response    => [$body, $headers],
            );
        }
        elsif ($headers->{Status} >= 200 && $headers->{Status} < 300) {
            return $content;
        }
        elsif ($headers->{Status} >= 500 && $headers->{Status} < 600) {
            if ($retries < 5) {
                my $sleeper = AnyEvent->condvar;
                AnyEvent->timer( after => ((4 ** $retries) / 10), cb => sub { $sleeper->send });
                $retries++;
                $sleeper->recv;
            }
            else {
                warn $headers->{Reason};
                SimpleDB::Class::Exception::Connection->throw(error=>'Exceeded maximum retries.', status_code=>$headers->{Status});
            }
        }
        else {
            SimpleDB::Class::Exception::Response->throw(
                error       => $content->{Errors}{Error}{Message},
                status_code => $headers->{Status},
                error_code  => $content->{Errors}{Error}{Code},
                box_usage   => $content->{Errors}{Error}{BoxUsage},
                request_id  => $content->{RequestID},
                response    => [$body, $headers],
            );
        }
    }
}

=head1 AUTHOR

JT Smith <jt_at_plainblack_com>

I have to give credit where credit is due: SimpleDB::Class is heavily inspired by L<DBIx::Class> by Matt Trout (and others), and the Amazon::SimpleDB class distributed by Amazon itself (not to be confused with Amazon::SimpleDB written by Timothy Appnel).

=head1 LEGAL

SimpleDB::Class is Copyright 2009 Plain Black Corporation and is licensed under the same terms as Perl itself.

=cut

no Moose;
__PACKAGE__->meta->make_immutable;
