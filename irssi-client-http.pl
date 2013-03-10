# irssi-client-api.pl -- enables remote control of irssi

use strict;

use Irssi;          # Interfacing with irssi
use Irssi::TextUI;  # Accessing scrollbacks

use HTTP::Daemon;   # HTTP connections
use HTTP::Status;   # HTTP Status codes
use HTTP::Response; # HTTP Responses

use URI;
use URI::QueryParam;

use Protocol::WebSocket;

use JSON;           # Producing JSON output

use vars qw($VERSION %IRSSI);

$VERSION = '0.01';
%IRSSI = (
    authors     => 'Axel Eirola',
    contact     => 'axel.eirola@iki.fi',
    name        => 'irssi client api',
    description => 'This script allows ' .
                   'remote clients to  ' .
                   'control irssi.',
    license     => 'Public Domain',
);

our ($server,           # Stores the server information
     $connections,      # Stores client connections information
#    $server_tag,        # Stores the irssi tag of the server input listener
#    $client,            # Stores the client filehandle (should maybe be an array)
#    $client_tag,        # Stores the irssi tag of the client input listener
#    $hs,
#    $frame,
);

sub add_settings {
    Irssi::settings_add_int('rest', 'rest_tcp_port', 10000);
    Irssi::settings_add_str('rest', 'rest_password', 's3cr3t');
}

sub setup {
    log_to_console("%B>>%n Setting up client api");
    add_settings();
    setup_tcp_socket();
}

##
#   Socket handling
##
sub setup_tcp_socket() {
    my $server_port = Irssi::settings_get_int('rest_tcp_port');
    my $handle = HTTP::Daemon->new(LocalPort => $server_port,
                                            Type      => SOCK_STREAM,
                                            Reuse     => 1,
                                            Listen    => 1 )
        or die "Couldn't be a tcp server on port $server_port : $@\n";
    $server->{handle} = $handle;

    # Add handler for server connections
    my $tag = Irssi::input_add(fileno($handle),
                                   Irssi::INPUT_READ,
                                   \&handle_connection, $server);

    $server->{tag} = $tag;
    $connections = [];
    log_to_console("%B>>%n Client api set up in tcp mode");
}

sub handle_connection() {
    my $server = shift;
    my $handle = $server->{handle}->accept();

    log_to_console("client_handle connected at $handle");

    my $connection = {
        "handle" => $handle,
        "tag" => 0,
    };

    # Add handler for connection messages
    my $tag = Irssi::input_add(fileno($handle),
                                   Irssi::INPUT_READ,
                                   \&handle_message, $connection);
    $connection->{tag} = $tag;
    push(@$connections, $connection);
}

sub handle_message($) {
    my $connection = shift;
    if ($connection->{frame}) {
        handle_websocket_message($connection);
    } else {
        handle_http_request($connection);
    }
}

sub handle_websocket_message($) {
    my $connection = shift;
    my $client = $connection->{handle};
    my $frame = $connection->{frame};

    my $rs = $client->sysread(my $chunk, 1024);
    if ($rs) {
        $frame->append($chunk);
        while (my $message = $frame->next) {
            log_to_console($message);
            print $client $frame->new($message)->to_bytes();
        }
    } else {
        log_to_console("fail");
        destroy_connection($connection);
    }
}

sub handle_http_request($) {
    my $connection = shift;
    my $client = $connection->{handle};
    my $request = $client->get_request;

    if (!$request) {
        Irssi::print("%B>>%n: Closing connection: " . $client->reason, MSGLEVEL_CLIENTCRAP);
        destroy_connection($connection);
        return;
    }

    if (!isAuthenticated($request)) {
        $client->send_error(RC_UNAUTHORIZED);
        return;
    }

    # Handle websocket initiations
    if ($request->method eq "GET" && $request->url =~ /^\/websocket\/?$/) {
        print "starting websocket";
        my $hs = Protocol::WebSocket::Handshake::Server->new;
        my $frame = $hs->build_frame;
        
        $connection->{handshake} = $hs;
        $connection->{frame} = $frame;

        $hs->parse($request->as_string);
        print $client $hs->to_string;
        $connection->{websocket} = 1;
        print "WebSocket started";

        return;
    }

    my $response = HTTP::Response->new(RC_OK);
    my $responseJson = perform_command($request);
    $response->header('Content-Type' => 'application/json');
    $response->header('Access-Control-Allow-Origin' => '*');
    
    if ($responseJson) {
        $response->content(to_json($responseJson, {utf8 => 1, pretty => 1}));
    }
    
    $client->send_response($response);
}

sub isAuthenticated($) {
    my $request = shift;
    my $password = Irssi::settings_get_str('rest_password');
    if ($password) {
        my $requestHeader = $request->header("Secret");
        return $requestHeader eq $password;
    } else {
        return 1;
    }
}

sub destroy_clients() {

}

sub destroy_connection($) {
    my $socket = shift;
    Irssi::input_remove($socket->{tag});
    undef($socket->{tag});
    if (defined $socket->{handle}) {
        close($socket->{handle});
        undef($socket->{handle});
    }
}

sub destroy_server() {
    destroy_connection($server);
}

sub destroy_socket() {
    destroy_clients();
    destroy_server();
}

##
#   Command handling
##
sub perform_command($) {
    my $request = shift;
    my $method = $request->method;
    my $url = $request->uri->path;

    my $data = $request->content;

    # Debug, write every processed command
    Irssi::print(
        "%B>>%n $IRSSI{name} received command: $method $url $data",
        MSGLEVEL_CLIENTCRAP);
    

    my $json;

    if ($method eq "GET" && $url =~ /^\/windows\/?$/) {
        # List all windows
        $json = [];
        foreach (Irssi::windows()) {
            my $window = $_;
            my @items = $window->items();
            my $item = $items[0];

            my $windowJson = {
                "refnum" => $window->{refnum},
                "type" => $item->{type} || "EMPTY",
                "name" => $item->{name} || $window->{name},
                "topic" => $item->{topic}
            };
            push(@$json, $windowJson);
        }
    } elsif ($method eq "GET" && $url =~ /^\/windows\/([0-9]+)\/?$/) {
        my $window = Irssi::window_find_refnum($1);
        if ($window) {
            my @items = $window->items();
            my $item = $items[0];

            $json = {
                "refnum" => $window->{refnum},
                "type" => $item->{type} || "EMPTY",
                "name" => $item->{name} || $window->{name},
                "topic" => $item->{topic}
            };

            # Nicks
            if ($item->{type}) {
                my $nicksJson = [];
                my @nicks = $item->nicks();
                foreach (@nicks) {
                    push(@$nicksJson, $_->{nick});
                }
                $json->{'nicks'} = $nicksJson;
            }

            $json->{'lines'} = getWindowLines($window, $request);
        }
    } elsif ($method eq "GET" && $url =~ /^\/windows\/([0-9]+)\/lines\/?$/) {
        my $window = Irssi::window_find_refnum($1);
        if ($window) {
            $json = getWindowLines($window, $request);
        } else {
            $json = [];
        }
    } elsif ($method eq "POST" && $url =~ /^\/windows\/([0-9]+)\/?$/) {
        # Skip empty lines
        return if $data =~ /^\s$/;

        # Say to channel on window
        my $window = Irssi::window_find_refnum($1);
        if ($window) {
            my @items = $window->items();
            my $item = $items[0];
            if ($item->{type}) {
                $item->command("msg * $data");
            } else {
                $window->print($data);
            }
        }
    } else {
        $json = {
            "GET" => {
                "windows" => "List all windows",
                "windows/[window_id]" => "List window content",
                "windows/[window_id]/lines?timestamp=[limit]" => "List window lines",
            },
            "POST" => {
                "windows/[id]" => "Post message to window"
            }
        };
    }

    return $json;
}

sub getWindowLines() {
    my $window = shift;
    my $request = shift;

    my $view = $window->view;
    my $buffer = $view->{buffer};
    my $line = $buffer->{cur_line};

    # Max lines
    my $count = 500;

    # Limit by timestamp
    my $timestampLimit =  $request->uri->query_param("timestamp");
    $timestampLimit = $timestampLimit ? $timestampLimit : 0;

    # Return empty if no new lines
    if ($line->{info}->{time} <= $timestampLimit) {
        return [];
    }

    # Scroll backwards until we find first line we want to add
    while($count) {
        my $prev = $line->prev;
        if ($prev and ($prev->{info}->{time} > $timestampLimit)) {
            $line = $prev;
            $count--;
        } else {
            # Break from loop if list ends
            $count = 0;
        }
    }

    my $linesArray = [];
    # Scroll forwards and add all lines till end
    while($line) {
        push(@$linesArray, {
            "timestamp" => $line->{info}->{time},
            "text" => $line->get_text(0),
        });
        $line = $line->next();
    }

    return $linesArray;
}

##
#   Misc stuff
##
sub teardown() {
    destroy_socket();
}

sub log_to_console() {
    my $message = shift;
    Irssi::print($message, MSGLEVEL_CLIENTCRAP);
}

# Setup on load
setup();

# Teardown on unload
Irssi::signal_add_first
    'command script unload', sub {
        my ($script) = @_;
        return unless $script =~
            /(?:^|\s) $IRSSI{name}
             (?:\.[^. ]*)? (?:\s|$) /x;
        teardown();
        Irssi::print("%B>>%n $IRSSI{name} $VERSION unloaded", MSGLEVEL_CLIENTCRAP);
    };    
Irssi::print("%B>>%n $IRSSI{name} $VERSION (by $IRSSI{authors}) loaded", MSGLEVEL_CLIENTCRAP);
