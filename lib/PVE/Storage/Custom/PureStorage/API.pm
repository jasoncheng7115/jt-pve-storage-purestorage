# Pure Storage FlashArray REST API Client
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::PureStorage::API;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON;
use URI;
use URI::Escape qw(uri_escape);
use MIME::Base64;
use Carp qw(croak);

# Constants
use constant {
    DEFAULT_TIMEOUT     => 30,
    DEFAULT_RETRY_COUNT => 3,
    DEFAULT_RETRY_DELAY => 2,
    API_VERSION_1X      => '1.19',  # Pure Storage REST API 1.x (legacy)
    API_VERSION_2X      => '2.26',  # Pure Storage REST API 2.x (modern)
};

# Supported API versions in order of preference (prefer 2.x)
my @SUPPORTED_API_VERSIONS = ('2.26', '2.21', '2.16', '2.11', '2.4', '2.0', '1.19', '1.17', '1.16');

# Constructor
sub new {
    my ($class, %opts) = @_;

    croak "host is required" unless $opts{host};
    # Either api_token or username+password is required
    unless ($opts{api_token} || ($opts{username} && $opts{password})) {
        croak "api_token or username+password is required";
    }

    my $self = {
        host        => $opts{host},
        api_token   => $opts{api_token},
        username    => $opts{username},
        password    => $opts{password},
        port        => $opts{port} // 443,
        ssl_verify  => $opts{ssl_verify} // 0,
        timeout     => $opts{timeout} // DEFAULT_TIMEOUT,
        retry_count => $opts{retry_count} // DEFAULT_RETRY_COUNT,
        retry_delay => $opts{retry_delay} // DEFAULT_RETRY_DELAY,
        api_version => $opts{api_version},  # Will be auto-detected if not specified
        _ua         => undef,
        _session_token => undef,
        _api_major  => undef,  # 1 or 2, set after version detection
    };

    bless $self, $class;
    $self->_init_ua();

    # Auto-detect API version if not specified
    unless ($self->{api_version}) {
        $self->_detect_api_version();
    }
    $self->_set_api_major();

    return $self;
}

# Detect best available API version
sub _detect_api_version {
    my ($self) = @_;

    # First check what versions are supported via api_version endpoint
    my $url = "https://$self->{host}:$self->{port}/api/api_version";
    my $req = HTTP::Request->new(GET => $url);
    my $resp = $self->{_ua}->request($req);

    if ($resp->is_success) {
        my $data = eval { decode_json($resp->decoded_content) };
        if ($data && $data->{version} && ref($data->{version}) eq 'ARRAY') {
            my %supported = map { $_ => 1 } @{$data->{version}};
            # Find the best version we support that the array also supports
            for my $version (@SUPPORTED_API_VERSIONS) {
                if ($supported{$version}) {
                    $self->{api_version} = $version;
                    return;
                }
            }
        }
    }

    # Fall back to trying each version
    for my $version (@SUPPORTED_API_VERSIONS) {
        $url = "https://$self->{host}:$self->{port}/api/$version";
        $req = HTTP::Request->new(GET => $url);
        $resp = $self->{_ua}->request($req);

        # Check if endpoint exists
        if ($resp->is_success) {
            my $body = $resp->decoded_content // '';
            if ($body =~ /"errors"/ || $body =~ /"message"\s*:\s*"Not found/i) {
                next;
            }
            $self->{api_version} = $version;
            return;
        } elsif ($resp->code == 401 || $resp->code == 403) {
            $self->{api_version} = $version;
            return;
        }
    }

    # Fall back to 2.26 as default (modern)
    $self->{api_version} = API_VERSION_2X;
}

# Get detected API version
sub get_api_version {
    my ($self) = @_;
    return $self->{api_version};
}

# Set API major version flag for conditional logic
sub _set_api_major {
    my ($self) = @_;

    if ($self->{api_version} =~ /^2\./) {
        $self->{_api_major} = 2;
    } else {
        $self->{_api_major} = 1;
    }
}

# Check if using API 2.x
sub is_api_v2 {
    my ($self) = @_;
    return ($self->{_api_major} // 1) >= 2;
}

# Initialize LWP::UserAgent
sub _init_ua {
    my ($self) = @_;

    my $ua = LWP::UserAgent->new(
        timeout         => $self->{timeout},
        ssl_opts        => {
            verify_hostname => $self->{ssl_verify},
            SSL_verify_mode => $self->{ssl_verify} ? 1 : 0,
        },
    );

    # Only set Accept header as default
    # Content-Type will be set per-request for POST/PUT/PATCH only
    $ua->default_header('Accept' => 'application/json');

    $self->{_ua} = $ua;
}

# Build API URL
sub _build_url {
    my ($self, $endpoint) = @_;

    $endpoint =~ s|^/||;  # Remove leading slash if present
    return "https://$self->{host}:$self->{port}/api/$self->{api_version}/$endpoint";
}

# Get authentication headers
sub _get_auth_headers {
    my ($self) = @_;

    my %headers;

    # Use session token if we have one
    if ($self->{_session_token}) {
        $headers{'x-auth-token'} = $self->{_session_token};
    }
    # Otherwise, create session first
    elsif ($self->{api_token} || ($self->{username} && $self->{password})) {
        $self->_create_session();
        if ($self->{_session_token}) {
            $headers{'x-auth-token'} = $self->{_session_token};
        }
    }

    return %headers;
}

# Create session using API token or username/password
sub _create_session {
    my ($self) = @_;

    my $url;
    my $req;

    if ($self->is_api_v2()) {
        # API 2.x: POST to /login with api-token header
        $url = "https://$self->{host}:$self->{port}/api/$self->{api_version}/login";
        $req = HTTP::Request->new(POST => $url);

        if ($self->{api_token}) {
            $req->header('api-token' => $self->{api_token});
        } elsif ($self->{username} && $self->{password}) {
            # For username/password, first get api_token via 1.x API
            my $api_token = $self->_get_api_token_v1();
            $req->header('api-token' => $api_token) if $api_token;
        }
    } else {
        # API 1.x: POST to /auth/session
        $url = "https://$self->{host}:$self->{port}/api/$self->{api_version}/auth/session";
        $req = HTTP::Request->new(POST => $url);
        $req->header('Content-Type' => 'application/json');

        if ($self->{api_token}) {
            $req->header('api-token' => $self->{api_token});
        } elsif ($self->{username} && $self->{password}) {
            my $auth = encode_base64("$self->{username}:$self->{password}", '');
            $req->header('Authorization' => "Basic $auth");
        }
    }

    my $resp = $self->{_ua}->request($req);

    if ($resp->is_success) {
        # Get x-auth-token from response header
        my $token = $resp->header('x-auth-token');
        if ($token) {
            $self->{_session_token} = $token;
            return 1;
        }
        croak "Session created but no x-auth-token in response";
    }

    croak "Failed to create session: " . $resp->status_line .
          " (URL: $url, Method: POST, Has-API-Token: " . ($self->{api_token} ? 'yes' : 'no') . ")";
}

# Get API token using username/password (API 1.x method)
sub _get_api_token_v1 {
    my ($self) = @_;

    return undef unless $self->{username} && $self->{password};

    my $url = "https://$self->{host}:$self->{port}/api/1.19/auth/apitoken";
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json({
        username => $self->{username},
        password => $self->{password},
    }));

    my $resp = $self->{_ua}->request($req);

    if ($resp->is_success) {
        my $data = eval { decode_json($resp->decoded_content) };
        return $data->{api_token} if $data && $data->{api_token};
    }

    return undef;
}

# Execute API request with retry logic
sub _request {
    my ($self, $method, $endpoint, $data, %opts) = @_;

    my $url = $self->_build_url($endpoint);
    my $retry_count = $self->{retry_count};
    my $last_error;

    for my $attempt (1 .. $retry_count) {
        my $req = HTTP::Request->new($method => $url);

        # Add auth headers
        my %auth_headers = $self->_get_auth_headers();
        for my $key (keys %auth_headers) {
            $req->header($key => $auth_headers{$key});
        }

        if ($data && ($method eq 'POST' || $method eq 'PUT' || $method eq 'PATCH')) {
            $req->header('Content-Type' => 'application/json');
            $req->content(encode_json($data));
        }

        my $resp = $self->{_ua}->request($req);

        if ($resp->is_success) {
            my $content = $resp->decoded_content;
            return {} if !$content || $content eq '';
            my $decoded = eval { decode_json($content) };
            if ($@) {
                croak "Failed to parse JSON response from $method $endpoint: $@";
            }
            return $decoded;
        }

        # Handle specific error codes
        my $code = $resp->code;
        $last_error = "HTTP $code: " . $resp->status_line;

        # Parse error response if JSON
        eval {
            my $err = decode_json($resp->decoded_content);
            my $err_msg;

            # API 2.x format: { errors: [{ message: "...", context: "..." }] }
            if ($err->{errors} && ref($err->{errors}) eq 'ARRAY' && @{$err->{errors}}) {
                my @msgs;
                for my $e (@{$err->{errors}}) {
                    my $msg = $e->{message} // $e->{msg} // '';
                    my $ctx = $e->{context} // '';
                    push @msgs, $ctx ? "$msg (context: $ctx)" : $msg;
                }
                $err_msg = join('; ', @msgs);
            }
            # API 1.x format: { msg: "..." } or [{ msg: "..." }]
            elsif ($err->{msg}) {
                $err_msg = $err->{msg};
            } elsif (ref($err) eq 'ARRAY' && $err->[0] && $err->[0]{msg}) {
                $err_msg = $err->[0]{msg};
            }

            $last_error = "Pure Storage API: $err_msg" if $err_msg;
        };

        # Add diagnostic hints for common errors
        if ($code == 401) {
            $last_error .= " (Hint: Check API token validity)";
        } elsif ($code == 403) {
            $last_error .= " (Hint: Insufficient permissions for this operation)";
        } elsif ($code == 404) {
            $last_error .= " (Hint: Resource not found - check volume/host name)";
        } elsif ($code == 409) {
            $last_error .= " (Hint: Conflict - resource may already exist or be in use)";
        } elsif ($code == 400 && $last_error =~ /quota/i) {
            $last_error .= " (Hint: Storage quota exceeded)";
        } elsif ($code == 400 && $last_error =~ /capacity/i) {
            $last_error .= " (Hint: Insufficient storage capacity)";
        } elsif ($code == 503) {
            $last_error .= " (Hint: Array may be in maintenance mode or overloaded)";
        }

        # Session expired - try to refresh
        if ($code == 401 && $attempt == 1) {
            $self->{_session_token} = undef;
            eval { $self->_create_session(); };
            next if $self->{_session_token};
        }

        # Don't retry on client errors (4xx) except 401 (handled above) and 429 (rate limit)
        last if $code >= 400 && $code < 500 && $code != 429;

        # Don't retry non-idempotent POST on 5xx (could cause duplicate creation)
        last if $method eq 'POST' && $code >= 500;

        # Wait before retry
        if ($attempt < $retry_count) {
            sleep($self->{retry_delay} * $attempt);
        }
    }

    croak $last_error;
}

# GET request
sub get {
    my ($self, $endpoint, $params) = @_;

    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('GET', $endpoint);
}

# POST request
sub post {
    my ($self, $endpoint, $data) = @_;
    return $self->_request('POST', $endpoint, $data);
}

# PUT request
sub put {
    my ($self, $endpoint, $data) = @_;
    return $self->_request('PUT', $endpoint, $data);
}

# PATCH request
sub patch {
    my ($self, $endpoint, $data, $params) = @_;

    # Add query parameters if provided
    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('PATCH', $endpoint, $data);
}

# DELETE request
sub delete {
    my ($self, $endpoint, $params) = @_;

    # Add query parameters if provided (for API 2.x)
    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('DELETE', $endpoint);
}

#
# Array operations
#

# Get array info
sub array_get {
    my ($self) = @_;
    if ($self->is_api_v2()) {
        return $self->get('arrays');
    } else {
        return $self->get('array');
    }
}

# Get array space info
sub array_space {
    my ($self) = @_;
    if ($self->is_api_v2()) {
        return $self->get('arrays', { space => 'true' });
    } else {
        return $self->get('array', { space => 'true' });
    }
}

# Get managed capacity (for PVE status)
# If pod is specified, return pod capacity; otherwise return array capacity
sub get_managed_capacity {
    my ($self, $pod) = @_;

    my $resp;
    my $space;

    if ($pod) {
        # Get pod-specific capacity
        $resp = $self->pod_get($pod);
        if (ref($resp) eq 'HASH' && $resp->{items}) {
            $space = $resp->{items}[0];
        } elsif (ref($resp) eq 'ARRAY' && $resp->[0]) {
            $space = $resp->[0];
        } else {
            $space = $resp;
        }

        my $quota = $space->{quota_limit} // 0;
        my $used = 0;

        if ($space->{space}) {
            $used = $space->{space}{total_used} // $space->{space}{total_physical} // 0;
        }

        # If quota is 0 (unlimited), fall back to array capacity
        if ($quota > 0) {
            return {
                total     => $quota,
                used      => $used,
                available => $quota - $used,
            };
        }
        # Fall through to array capacity if no quota set
    }

    # Get array capacity
    $resp = $self->array_space();

    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $space = $resp->{items}[0];
    } elsif (ref($resp) eq 'ARRAY' && $resp->[0]) {
        $space = $resp->[0];
    } else {
        $space = $resp;
    }

    # API 2.x has nested 'space' object, API 1.x has flat structure
    my ($total, $used);
    if ($space->{space}) {
        # API 2.x format
        $total = $space->{capacity} // 0;
        $used = $space->{space}{total_used} // $space->{space}{total_physical} // 0;
    } else {
        # API 1.x format
        $total = $space->{capacity} // 0;
        $used = $space->{total} // $space->{volumes} // 0;
    }

    return {
        total     => $total,
        used      => $used,
        available => $total - $used,
    };
}

# Get pod info
sub pod_get {
    my ($self, $name) = @_;

    return $self->get("pods", { names => $name });
}

#
# Volume operations
#

# Create a volume
sub volume_create {
    my ($self, $name, $size) = @_;

    croak "name is required" unless $name;
    croak "size is required" unless $size;

    if ($self->is_api_v2()) {
        # API 2.x: POST /volumes?names=volname with provisioned in body
        # Note: names parameter must be in query string, not body
        # URL-encode the name (e.g., pod::volname -> pod%3A%3Avolname)
        my $encoded_name = uri_escape($name);
        return $self->post("volumes?names=$encoded_name", {
            provisioned => $size,
        });
    } else {
        # API 1.x
        return $self->post("volume/$name", { size => $size });
    }
}

# Get volume by name
# Returns volume hashref, or undef if volume does not exist.
# Dies on transient/unexpected API errors.
sub volume_get {
    my ($self, $name) = @_;

    my $resp;
    if ($self->is_api_v2()) {
        $resp = eval { $self->get("volumes", { names => $name }); };
    } else {
        $resp = eval { $self->get("volume/$name"); };
    }
    if ($@) {
        # Only treat 404/not-found as "volume doesn't exist"
        return undef if $@ =~ /HTTP 404|not found|does not exist/i;
        # All other errors are unexpected - propagate them
        die $@;
    }

    # Handle API 2.x response format
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        return $resp->{items}[0];
    }
    if (ref($resp) eq 'ARRAY') {
        return $resp->[0];
    }
    return $resp;
}

# List volumes matching pattern
sub volume_list {
    my ($self, $pattern) = @_;

    my $params = {};
    my $resp;
    my $perl_filter_pattern;

    if ($self->is_api_v2()) {
        # API 2.x: GET /volumes
        # destroyed is a query parameter, not a filter parameter
        $params->{destroyed} = 'false';

        if ($pattern) {
            if ($pattern =~ /^([^:]+)::(.+)$/) {
                # Pattern has pod prefix: pod::pattern*
                # Use pod.name filter to limit results, then filter by name in Perl
                my ($pod, $volpattern) = ($1, $2);
                $params->{filter} = "pod.name='$pod'";
                $perl_filter_pattern = $pattern;
            } elsif ($pattern =~ /\*/) {
                # Wildcard pattern without pod - use filter parameter
                $params->{filter} = "name='$pattern'";
            } else {
                # Exact name - use names parameter
                $params->{names} = $pattern;
            }
        }
        $resp = $self->get('volumes', $params);
    } else {
        # API 1.x: use names parameter
        if ($pattern) {
            $params->{names} = $pattern;
        }
        $resp = $self->get('volume', $params);
    }

    # Handle API 2.x response format
    my $volumes;
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $volumes = $resp->{items};
    } elsif (!$resp) {
        return [];
    } elsif (ref($resp) eq 'ARRAY') {
        $volumes = $resp;
    } else {
        $volumes = [$resp];
    }

    # Filter out destroyed volumes (fallback for API 1.x)
    my @active = grep { !$_->{destroyed} } @$volumes;

    # Apply Perl pattern filter if needed (for patterns with :: that API filter can't handle fully)
    if ($perl_filter_pattern) {
        # Convert glob pattern to regex: * -> .*, escape other regex chars
        my $regex = $perl_filter_pattern;
        $regex =~ s/([.+?^\${}()|[\]\\])/\\$1/g;  # Escape regex special chars except *
        $regex =~ s/\*/.*/g;  # Convert * to .*
        $regex = "^${regex}\$";  # Anchor pattern
        @active = grep { $_->{name} && $_->{name} =~ /$regex/ } @active;
    }

    return \@active;
}

# List destroyed volumes matching pattern (for disaster recovery)
sub volume_list_destroyed {
    my ($self, $pattern) = @_;

    my $params = {};
    my $resp;
    my $perl_filter_pattern;

    if ($self->is_api_v2()) {
        # API 2.x: GET /volumes?destroyed=true
        $params->{destroyed} = 'true';

        if ($pattern) {
            if ($pattern =~ /^([^:]+)::(.+)$/) {
                my ($pod, $volpattern) = ($1, $2);
                $params->{filter} = "pod.name='$pod'";
                $perl_filter_pattern = $pattern;
            } elsif ($pattern =~ /\*/) {
                $params->{filter} = "name='$pattern'";
            } else {
                $params->{names} = $pattern;
            }
        }
        $resp = $self->get('volumes', $params);
    } else {
        # API 1.x: use names parameter with pending=true
        if ($pattern) {
            $params->{names} = $pattern;
        }
        $params->{pending} = 'true';
        $resp = $self->get('volume', $params);
    }

    my $volumes;
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $volumes = $resp->{items};
    } elsif (!$resp) {
        return [];
    } elsif (ref($resp) eq 'ARRAY') {
        $volumes = $resp;
    } else {
        $volumes = [$resp];
    }

    # Filter to only destroyed volumes
    my @destroyed = grep { $_->{destroyed} } @$volumes;

    # Apply Perl pattern filter if needed
    if ($perl_filter_pattern) {
        my $regex = $perl_filter_pattern;
        $regex =~ s/([.+?^\${}()|[\]\\])/\\$1/g;
        $regex =~ s/\*/.*/g;
        $regex = "^${regex}\$";
        @destroyed = grep { $_->{name} && $_->{name} =~ /$regex/ } @destroyed;
    }

    return \@destroyed;
}

# Recover a destroyed volume
sub volume_recover {
    my ($self, $name) = @_;

    croak "volume name is required" unless $name;

    if ($self->is_api_v2()) {
        # API 2.x: PATCH /volumes with destroyed=false
        $self->patch("volumes", { destroyed => JSON::false }, { names => $name });
    } else {
        # API 1.x: PUT /volume/{name} with destroyed=false
        $self->put("volume/$name", { destroyed => JSON::false });
    }

    return 1;
}

# Delete a volume (requires 2 steps: destroy then eradicate)
sub volume_delete {
    my ($self, $name, %opts) = @_;

    if ($self->is_api_v2()) {
        # API 2.x: PATCH to destroy, then DELETE to eradicate
        $self->patch("volumes", { destroyed => JSON::true }, { names => $name });
        unless ($opts{skip_eradicate}) {
            $self->delete("volumes", { names => $name });
        }
    } else {
        # API 1.x
        $self->put("volume/$name", { destroyed => JSON::true });
        unless ($opts{skip_eradicate}) {
            $self->delete("volume/$name");
        }
    }

    return 1;
}

# Resize a volume
sub volume_resize {
    my ($self, $name, $new_size) = @_;

    croak "name is required" unless $name;
    croak "new_size is required" unless $new_size;

    if ($self->is_api_v2()) {
        return $self->patch("volumes", { provisioned => $new_size }, { names => $name });
    } else {
        return $self->put("volume/$name", { size => $new_size });
    }
}

# Rename a volume
sub volume_rename {
    my ($self, $old_name, $new_name) = @_;

    croak "old_name is required" unless $old_name;
    croak "new_name is required" unless $new_name;

    if ($self->is_api_v2()) {
        return $self->patch("volumes", { name => $new_name }, { names => $old_name });
    } else {
        return $self->put("volume/$old_name", { name => $new_name });
    }
}

# Get volume serial number (for WWID)
sub volume_get_serial {
    my ($self, $name) = @_;

    my $vol = $self->volume_get($name);
    return $vol ? $vol->{serial} : undef;
}

# Convert serial to WWID
# Pure Storage WWID format: naa.624a9370 + serial(24 chars)
sub serial_to_wwid {
    my ($self, $serial) = @_;

    return undef unless $serial;

    # Pure Storage NAA prefix
    # The full WWID is: 3624a9370 + serial (lowercase)
    return '3624a9370' . lc($serial);
}

# Get volume WWID
sub volume_get_wwid {
    my ($self, $name) = @_;

    my $serial = $self->volume_get_serial($name);
    return $self->serial_to_wwid($serial);
}

# Clone a volume (from source volume or snapshot)
sub volume_clone {
    my ($self, $name, $source) = @_;

    croak "name is required" unless $name;
    croak "source is required" unless $source;

    if ($self->is_api_v2()) {
        # API 2.x: POST /volumes?names=volname with source in body
        # Note: names parameter must be in query string, not body
        # URL-encode the name (e.g., pod::volname -> pod%3A%3Avolname)
        my $encoded_name = uri_escape($name);
        return $self->post("volumes?names=$encoded_name", {
            source => { name => $source },
        });
    } else {
        # API 1.x
        return $self->post("volume/$name", { source => $source });
    }
}

# Overwrite volume from snapshot (rollback)
sub volume_overwrite {
    my ($self, $name, $source) = @_;

    croak "name is required" unless $name;
    croak "source is required" unless $source;

    if ($self->is_api_v2()) {
        # API 2.x: PATCH /volumes with source and overwrite flag
        return $self->patch("volumes", {
            source    => { name => $source },
            overwrite => JSON::true,
        }, { names => $name });
    } else {
        # API 1.x
        return $self->post("volume/$name", { overwrite => $source });
    }
}

#
# Snapshot operations
#

# Create a snapshot
# Pure snapshot naming: volume.suffix
sub snapshot_create {
    my ($self, $volume, $suffix) = @_;

    croak "volume is required" unless $volume;
    croak "suffix is required" unless $suffix;

    if ($self->is_api_v2()) {
        # API 2.x: POST /volume-snapshots?source_names=volname with suffix in body
        # Note: source_names parameter must be in query string
        # URL-encode the volume name (e.g., pod::volname -> pod%3A%3Avolname)
        my $encoded_volume = uri_escape($volume);
        return $self->post("volume-snapshots?source_names=$encoded_volume", {
            suffix => $suffix,
        });
    } else {
        # API 1.x: POST /volume with snap=true in body
        return $self->post("volume", {
            snap   => JSON::true,
            source => [$volume],
            suffix => $suffix,
        });
    }
}

# Get snapshot by name
# Returns snapshot hashref, or undef if snapshot does not exist.
# Dies on transient/unexpected API errors.
sub snapshot_get {
    my ($self, $snapname) = @_;

    my $resp;
    if ($self->is_api_v2()) {
        # API 2.x: GET /volume-snapshots?names=snapname
        $resp = eval { $self->get("volume-snapshots", { names => $snapname }); };
    } else {
        # API 1.x: GET /volume/snapname?snap=true
        $resp = eval { $self->get("volume/$snapname", { snap => 'true' }); };
    }
    if ($@) {
        return undef if $@ =~ /HTTP 404|not found|does not exist/i;
        die $@;
    }

    # Handle API 2.x response format
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        return $resp->{items}[0];
    }
    if (ref($resp) eq 'ARRAY') {
        return $resp->[0];
    }
    return $resp;
}

# List snapshots for a volume
sub snapshot_list {
    my ($self, $volume, $pattern) = @_;

    my $params = {};
    my $resp;
    my $perl_filter_pattern;  # For patterns that can't be handled by API filter
    my $perl_filter_volume;   # For volume names with :: that API can't handle

    if ($self->is_api_v2()) {
        # API 2.x: GET /volume-snapshots
        # Use filter parameter for wildcards, names for exact matches
        my @filters;
        if ($volume) {
            if ($volume =~ /^([^:]+)::(.+)$/) {
                # Volume has pod prefix - use pod.name filter to limit results
                my $pod = $1;
                push @filters, "pod.name='$pod'";
                $perl_filter_volume = $volume;  # Will filter by exact volume in Perl
            } else {
                push @filters, "source.name='$volume'";
            }
        }
        if ($pattern) {
            if ($pattern =~ /^([^:]+)::(.+)$/) {
                # Pattern has pod prefix - use pod.name filter
                my $pod = $1;
                # Only add pod filter if not already added from volume
                push @filters, "pod.name='$pod'" unless grep { /pod\.name/ } @filters;
                $perl_filter_pattern = $pattern;
            } elsif ($pattern =~ /\*/) {
                # Wildcard pattern without pod
                push @filters, "name='$pattern'";
            } else {
                # Exact name
                $params->{names} = $pattern;
            }
        }
        if (@filters) {
            $params->{filter} = join(' and ', @filters);
        }
        $resp = $self->get('volume-snapshots', $params);
    } else {
        # API 1.x
        $params->{snap} = 'true';
        if ($volume) {
            $params->{source} = $volume;
        }
        if ($pattern) {
            $params->{names} = $pattern;
        }
        $resp = $self->get('volume', $params);
    }

    # Handle API 2.x response format
    my $snapshots;
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $snapshots = $resp->{items};
    } elsif (!$resp) {
        return [];
    } elsif (ref($resp) eq 'ARRAY') {
        $snapshots = $resp;
    } else {
        $snapshots = [$resp];
    }

    # Apply Perl pattern filter if needed (for patterns with :: that API can't handle)
    if ($perl_filter_pattern) {
        # Convert glob pattern to regex
        my $regex = $perl_filter_pattern;
        $regex =~ s/([.+?^\${}()|[\]\\])/\\$1/g;  # Escape regex special chars except *
        $regex =~ s/\*/.*/g;  # Convert * to .*
        $regex = "^${regex}\$";  # Anchor pattern
        $snapshots = [grep { $_->{name} && $_->{name} =~ /$regex/ } @$snapshots];
    }

    # Filter by volume if it contains :: (API filter only filtered by pod, not exact volume)
    if ($perl_filter_volume) {
        $snapshots = [grep {
            my $src = $_->{source}{name} // $_->{source} // '';
            $src eq $perl_filter_volume
        } @$snapshots];
    }

    return $snapshots;
}

# Delete a snapshot
sub snapshot_delete {
    my ($self, $snapname, %opts) = @_;

    if ($self->is_api_v2()) {
        # API 2.x: PATCH to destroy, DELETE to eradicate
        $self->patch("volume-snapshots", { destroyed => JSON::true }, { names => $snapname });
        unless ($opts{skip_eradicate}) {
            $self->delete("volume-snapshots", { names => $snapname });
        }
    } else {
        # API 1.x
        $self->put("volume/$snapname", { destroyed => JSON::true });
        unless ($opts{skip_eradicate}) {
            $self->delete("volume/$snapname");
        }
    }

    return 1;
}

#
# Host operations
#

# Create a host
sub host_create {
    my ($self, $name, %opts) = @_;

    croak "name is required" unless $name;

    my $data = {};

    if ($self->is_api_v2()) {
        # API 2.x format: names in query parameter, iqns/wwns in body
        if ($opts{iqns} && @{$opts{iqns}}) {
            $data->{iqns} = $opts{iqns};
        }
        if ($opts{wwns} && @{$opts{wwns}}) {
            $data->{wwns} = $opts{wwns};
        }
        # API 2.x uses POST /hosts?names=hostname with data in body
        my $encoded_name = uri_escape($name);
        return $self->post("hosts?names=$encoded_name", $data);
    } else {
        # API 1.x format
        if ($opts{iqns} && @{$opts{iqns}}) {
            $data->{iqnlist} = $opts{iqns};
        }
        if ($opts{wwns} && @{$opts{wwns}}) {
            $data->{wwnlist} = $opts{wwns};
        }
        return $self->post("host/$name", $data);
    }
}

# Get host by name
# Returns host hashref, or undef if host does not exist.
# Dies on transient/unexpected API errors.
sub host_get {
    my ($self, $name) = @_;

    my $resp;
    if ($self->is_api_v2()) {
        # API 2.x: GET /hosts?names=hostname
        $resp = eval { $self->get("hosts", { names => $name }); };
    } else {
        # API 1.x: GET /host/hostname
        $resp = eval { $self->get("host/$name"); };
    }
    if ($@) {
        return undef if $@ =~ /HTTP 404|not found|does not exist/i;
        die $@;
    }

    # Handle API 2.x response format (items array)
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        return $resp->{items}[0];
    }
    if (ref($resp) eq 'ARRAY') {
        return $resp->[0];
    }
    return $resp;
}

# List hosts
sub host_list {
    my ($self, $pattern) = @_;

    my $params = {};
    if ($pattern) {
        $params->{names} = $pattern;
    }

    my $resp;
    if ($self->is_api_v2()) {
        $resp = $self->get('hosts', $params);
    } else {
        $resp = $self->get('host', $params);
    }

    # Handle API 2.x response format
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        return $resp->{items};
    }
    return [] unless $resp;
    return $resp if ref($resp) eq 'ARRAY';
    return [$resp];
}

# Get volumes connected to a host
sub host_get_volumes {
    my ($self, $host_name) = @_;

    croak "host_name is required" unless $host_name;

    my $resp;
    if ($self->is_api_v2()) {
        $resp = $self->get('connections', { host_names => $host_name });
    } else {
        $resp = $self->get("host/$host_name/volume");
    }

    # Handle API 2.x response format
    my $connections;
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $connections = $resp->{items};
    } elsif (!$resp) {
        return [];
    } elsif (ref($resp) eq 'ARRAY') {
        $connections = $resp;
    } else {
        $connections = [$resp];
    }

    # Extract volume names from connections
    my @volumes;
    for my $conn (@$connections) {
        if ($conn->{vol} && $conn->{vol}{name}) {
            push @volumes, $conn->{vol}{name};
        } elsif ($conn->{volume} && $conn->{volume}{name}) {
            push @volumes, $conn->{volume}{name};
        } elsif ($conn->{name}) {
            # API 1.x format
            push @volumes, $conn->{name};
        }
    }

    return \@volumes;
}

# Delete a host
sub host_delete {
    my ($self, $name) = @_;

    if ($self->is_api_v2()) {
        return $self->delete("hosts", { names => $name });
    } else {
        return $self->delete("host/$name");
    }
}

# Add initiator (IQN or WWN) to host
sub host_add_initiator {
    my ($self, $host_name, $initiator, $type) = @_;

    croak "host_name is required" unless $host_name;
    croak "initiator is required" unless $initiator;

    $type //= 'iqn';  # Default to iSCSI

    if ($self->is_api_v2()) {
        # API 2.x: PATCH /hosts replaces the entire iqns/wwns array,
        # so we must fetch existing initiators and merge before patching.
        my $host = $self->host_get($host_name);
        croak "Host '$host_name' not found" unless $host;

        my $data;
        if ($type eq 'wwn') {
            my @existing = @{$host->{wwns} // []};
            # Only add if not already present (case-insensitive comparison)
            unless (grep { lc($_) eq lc($initiator) } @existing) {
                push @existing, $initiator;
            }
            $data = { wwns => \@existing };
        } else {
            my @existing = @{$host->{iqns} // []};
            unless (grep { lc($_) eq lc($initiator) } @existing) {
                push @existing, $initiator;
            }
            $data = { iqns => \@existing };
        }
        return $self->patch("hosts", $data, { names => $host_name });
    } else {
        # API 1.x format: addwwnlist/addiqnlist appends correctly
        my $data;
        if ($type eq 'wwn') {
            $data = { addwwnlist => [$initiator] };
        } else {
            $data = { addiqnlist => [$initiator] };
        }
        return $self->put("host/$host_name", $data);
    }
}

# Remove initiator from host
sub host_remove_initiator {
    my ($self, $host_name, $initiator, $type) = @_;

    croak "host_name is required" unless $host_name;
    croak "initiator is required" unless $initiator;

    $type //= 'iqn';

    if ($self->is_api_v2()) {
        # API 2.x: PATCH /hosts replaces the entire iqns/wwns array,
        # so we must fetch existing initiators, remove the target, then patch back.
        my $host = $self->host_get($host_name);
        croak "Host '$host_name' not found" unless $host;

        my $data;
        if ($type eq 'wwn') {
            my @remaining = grep { lc($_) ne lc($initiator) } @{$host->{wwns} // []};
            $data = { wwns => \@remaining };
        } else {
            my @remaining = grep { lc($_) ne lc($initiator) } @{$host->{iqns} // []};
            $data = { iqns => \@remaining };
        }
        return $self->patch("hosts", $data, { names => $host_name });
    } else {
        # API 1.x format: remwwnlist/remiqnlist removes correctly
        my $data;
        if ($type eq 'wwn') {
            $data = { remwwnlist => [$initiator] };
        } else {
            $data = { remiqnlist => [$initiator] };
        }
        return $self->put("host/$host_name", $data);
    }
}

# Get or create host
sub host_get_or_create {
    my ($self, $name, %opts) = @_;

    my $host = $self->host_get($name);
    return $host if $host;

    eval { $self->host_create($name, %opts); };
    if ($@) {
        # May fail if already exists (race condition)
        $host = $self->host_get($name);
        return $host if $host;
        croak $@;
    }

    return $self->host_get($name);
}

#
# Host Group operations
#

# Create a host group
sub hgroup_create {
    my ($self, $name, %opts) = @_;

    croak "name is required" unless $name;

    my $data = {};
    if ($opts{hosts} && @{$opts{hosts}}) {
        $data->{hostlist} = $opts{hosts};
    }

    return $self->post("hgroup/$name", $data);
}

# Get host group
sub hgroup_get {
    my ($self, $name) = @_;

    my $resp = eval { $self->get("hgroup/$name"); };
    return undef if $@;

    if (ref($resp) eq 'ARRAY') {
        return $resp->[0];
    }
    return $resp;
}

# List host groups
sub hgroup_list {
    my ($self, $pattern) = @_;

    my $params = {};
    if ($pattern) {
        $params->{names} = $pattern;
    }

    my $resp = $self->get('hgroup', $params);

    return [] unless $resp;
    return $resp if ref($resp) eq 'ARRAY';
    return [$resp];
}

#
# Volume <-> Host connection operations
#

# Connect volume to host
sub volume_connect_host {
    my ($self, $volume, $host) = @_;

    croak "volume is required" unless $volume;
    croak "host is required" unless $host;

    if ($self->is_api_v2()) {
        # API 2.x: POST /connections?host_names=hostname&volume_names=volname
        # Note: host_names and volume_names must be in query string
        # URL-encode the volume name (e.g., pod::volname -> pod%3A%3Avolname)
        my $encoded_volume = uri_escape($volume);
        my $encoded_host = uri_escape($host);
        return $self->post("connections?host_names=$encoded_host&volume_names=$encoded_volume", {});
    } else {
        # API 1.x
        return $self->post("host/$host/volume/$volume");
    }
}

# Disconnect volume from host
sub volume_disconnect_host {
    my ($self, $volume, $host) = @_;

    croak "volume is required" unless $volume;
    croak "host is required" unless $host;

    if ($self->is_api_v2()) {
        # API 2.x: DELETE /connections with query params
        return $self->delete("connections", {
            host_names   => $host,
            volume_names => $volume,
        });
    } else {
        # API 1.x
        return $self->delete("host/$host/volume/$volume");
    }
}

# Check if volume is connected to host
sub volume_is_connected {
    my ($self, $volume, $host) = @_;

    my $resp;
    if ($self->is_api_v2()) {
        # API 2.x: GET /connections
        $resp = eval {
            $self->get("connections", {
                host_names   => $host,
                volume_names => $volume,
            });
        };
    } else {
        # API 1.x
        $resp = eval { $self->get("host/$host/volume/$volume"); };
    }
    return 0 if $@;

    # Handle API 2.x response format
    if (ref($resp) eq 'HASH' && exists $resp->{items}) {
        return scalar(@{$resp->{items}}) > 0 ? 1 : 0;
    }
    return 1 if $resp;
    return 0;
}

# Get all connections for a volume
sub volume_get_connections {
    my ($self, $volume) = @_;

    my $resp;
    if ($self->is_api_v2()) {
        # API 2.x: GET /connections?volume_names=volume
        $resp = eval { $self->get("connections", { volume_names => $volume }); };
    } else {
        # API 1.x
        $resp = eval { $self->get("volume/$volume/host"); };
    }
    return [] if $@;

    # Handle API 2.x response format
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        # Convert to simpler format with host name
        return [ map { { name => $_->{host}{name} // $_->{host_name} } } @{$resp->{items}} ];
    }
    return [] unless $resp;
    return $resp if ref($resp) eq 'ARRAY';
    return [$resp];
}

# Connect volume to host group
sub volume_connect_hgroup {
    my ($self, $volume, $hgroup) = @_;

    croak "volume is required" unless $volume;
    croak "hgroup is required" unless $hgroup;

    if ($self->is_api_v2()) {
        # API 2.x: POST /connections?host_group_names=hgroupname&volume_names=volname
        # Note: host_group_names and volume_names must be in query string
        # URL-encode the names (e.g., pod::volname -> pod%3A%3Avolname)
        my $encoded_volume = uri_escape($volume);
        my $encoded_hgroup = uri_escape($hgroup);
        return $self->post("connections?host_group_names=$encoded_hgroup&volume_names=$encoded_volume", {});
    } else {
        # API 1.x
        return $self->post("hgroup/$hgroup/volume/$volume");
    }
}

# Disconnect volume from host group
sub volume_disconnect_hgroup {
    my ($self, $volume, $hgroup) = @_;

    croak "volume is required" unless $volume;
    croak "hgroup is required" unless $hgroup;

    if ($self->is_api_v2()) {
        # API 2.x
        return $self->delete("connections", {
            host_group_names => $hgroup,
            volume_names     => $volume,
        });
    } else {
        # API 1.x
        return $self->delete("hgroup/$hgroup/volume/$volume");
    }
}

#
# Network/Port operations
#

# Get iSCSI ports
sub iscsi_get_ports {
    my ($self) = @_;

    my $endpoint = $self->is_api_v2() ? 'ports' : 'port';
    my $resp = $self->get($endpoint);

    # Handle API 2.x response format
    my $ports;
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $ports = $resp->{items};
    } elsif (ref($resp) eq 'ARRAY') {
        $ports = $resp;
    } else {
        $ports = [$resp];
    }

    my @iscsi_ports;
    for my $port (@$ports) {
        next unless $port && $port->{iqn};  # Only iSCSI ports have IQN
        push @iscsi_ports, {
            name    => $port->{name},
            iqn     => $port->{iqn},
            portal  => $port->{portal},
            wwn     => $port->{wwn},
        };
    }

    return \@iscsi_ports;
}

# Get FC ports
sub fc_get_ports {
    my ($self) = @_;

    my $endpoint = $self->is_api_v2() ? 'ports' : 'port';
    my $resp = $self->get($endpoint);

    # Handle API 2.x response format
    my $ports;
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        $ports = $resp->{items};
    } elsif (ref($resp) eq 'ARRAY') {
        $ports = $resp;
    } else {
        $ports = [$resp];
    }

    my @fc_ports;
    for my $port (@$ports) {
        next unless $port && $port->{wwn} && !$port->{iqn};  # FC ports have WWN but no IQN
        push @fc_ports, {
            name => $port->{name},
            wwn  => $port->{wwn},
        };
    }

    return \@fc_ports;
}

# Get network interfaces (for iSCSI discovery)
sub network_get_interfaces {
    my ($self) = @_;

    my $endpoint = $self->is_api_v2() ? 'network-interfaces' : 'network';
    my $resp = eval { $self->get($endpoint); };
    return [] if $@;

    return [] unless $resp;
    # Handle API 2.x response format
    if (ref($resp) eq 'HASH' && $resp->{items}) {
        return $resp->{items};
    }
    return $resp if ref($resp) eq 'ARRAY';
    return [$resp];
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::PureStorage::API - Pure Storage FlashArray REST API client

=head1 SYNOPSIS

    use PVE::Storage::Custom::PureStorage::API;

    my $api = PVE::Storage::Custom::PureStorage::API->new(
        host      => '192.168.1.100',
        api_token => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
    );

    # Or with username/password
    my $api = PVE::Storage::Custom::PureStorage::API->new(
        host     => '192.168.1.100',
        username => 'pureuser',
        password => 'secret',
    );

    # Create a volume
    $api->volume_create('pve-pure1-100-disk0', 10 * 1024 * 1024 * 1024);

    # Connect volume to host
    $api->volume_connect_host('pve-pure1-100-disk0', 'pve-prod-node1');

    # Create snapshot
    $api->snapshot_create('pve-pure1-100-disk0', 'pve-snap-backup1');

=head1 DESCRIPTION

This module provides a Perl interface to the Pure Storage FlashArray REST API
for storage management operations required by the Proxmox VE storage plugin.

=cut
