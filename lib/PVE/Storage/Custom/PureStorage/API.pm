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
    # 15s timeout × 2 retries gives ~34s worst case per API call. The previous
    # 30s × 3 produced ~102s worst case which was long enough to wedge PVE
    # status polling when the array was unreachable.
    DEFAULT_TIMEOUT     => 15,
    DEFAULT_RETRY_COUNT => 2,
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

# Execute API request with retry logic.
#
# Options:
#   timeout => N   Per-call UA timeout override (seconds). Used by inherently
#                  slow operations like volume_destroy with snapshots, where
#                  the array can take 30+ seconds to respond. The original UA
#                  timeout is restored before returning, in every exit path.
sub _request {
    my ($self, $method, $endpoint, $data, %opts) = @_;

    my $url = $self->_build_url($endpoint);
    my $retry_count = $self->{retry_count};
    my $last_error;

    # Per-call timeout override
    my $orig_timeout = $self->{_ua}->timeout();
    if ($opts{timeout}) {
        $self->{_ua}->timeout($opts{timeout});
    }

    my $restore_timeout = sub {
        $self->{_ua}->timeout($orig_timeout) if $opts{timeout};
    };

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
            $restore_timeout->();
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

        # Session expired - try to refresh and retry once
        if ($code == 401 && $attempt < $retry_count) {
            warn "Pure Storage API returned 401, refreshing session token (attempt $attempt/$retry_count)\n";
            $self->{_session_token} = undef;
            eval { $self->_create_session(); };
            # Re-apply per-call timeout override after _create_session may
            # have rebuilt the UA.
            $self->{_ua}->timeout($opts{timeout}) if $opts{timeout};
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

    $restore_timeout->();
    croak $last_error;
}

# GET request
sub get {
    my ($self, $endpoint, $params, %opts) = @_;

    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('GET', $endpoint, undef, %opts);
}

# POST request
sub post {
    my ($self, $endpoint, $data, %opts) = @_;
    return $self->_request('POST', $endpoint, $data, %opts);
}

# PUT request
sub put {
    my ($self, $endpoint, $data, %opts) = @_;
    return $self->_request('PUT', $endpoint, $data, %opts);
}

# PATCH request
sub patch {
    my ($self, $endpoint, $data, $params, %opts) = @_;

    # Add query parameters if provided
    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('PATCH', $endpoint, $data, %opts);
}

# DELETE request
sub delete {
    my ($self, $endpoint, $params, %opts) = @_;

    # Add query parameters if provided (for API 2.x)
    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('DELETE', $endpoint, undef, %opts);
}

#
# Operator-friendly error translation
#

# Translate Pure FlashArray API error messages into operator-friendly
# wording. The raw API error tells WHAT happened but not WHY (what limit
# was hit?) or HOW to recover (delete things, raise the limit, contact
# Pure support?). This helper pattern-matches known Pure limit errors and
# prepends a short human summary while preserving the original error.
#
# Apply at every die site where backend errors can bubble up to the
# operator, e.g.:
#
#   die "Failed to create volume '$name': " .
#       PVE::Storage::Custom::PureStorage::API::translate_pure_error($@);
#
# Unknown errors pass through unchanged.
sub translate_pure_error {
    my ($err) = @_;
    return $err unless defined $err;

    # Per-array volume count limit. Pure FlashArray has a soft cap on the
    # total number of volumes per array. Hitting it usually means there
    # are many destroyed-but-not-eradicated volumes still consuming the
    # quota — they auto-eradicate after the array's eradication delay
    # (default 24h).
    if ($err =~ /maximum number of volumes/i ||
        $err =~ /volume.*limit.*reached/i ||
        $err =~ /too many volumes/i ||
        $err =~ /volume_limit_exceeded/i) {
        return "Pure FlashArray volume count limit reached. The plugin " .
               "creates one volume per VM disk, so this means the array " .
               "is at its volume cap. Check Pure UI > Storage > Volumes " .
               "for destroyed volumes still in the eradication delay " .
               "window (default 24h) — they continue to count against " .
               "the cap. Either wait, eradicate them manually, or ask " .
               "your storage admin to raise the limit. Original error: $err";
    }

    # Per-volume snapshot limit
    if ($err =~ /maximum number of snapshots/i ||
        $err =~ /snapshot.*limit.*reached/i ||
        $err =~ /too many snapshots/i) {
        return "Pure FlashArray snapshot count limit reached. Check Pure " .
               "UI > Protection > Volume Snapshots and delete old " .
               "PVE-managed snapshots, or ask your storage admin to raise " .
               "the limit. Original error: $err";
    }

    # Host or host-group connection limit
    if ($err =~ /maximum.*connection/i ||
        $err =~ /host.*limit/i ||
        $err =~ /connection.*limit.*reached/i) {
        return "Pure FlashArray host connection limit reached. Each PVE " .
               "node has its own host object (per-node mode) connected " .
               "to every Pure-managed VM disk. Either reduce the number " .
               "of disks, switch to shared host mode, or ask your storage " .
               "admin to raise the limit. Original error: $err";
    }

    # Protection group limit
    if ($err =~ /maximum.*protection.*group/i ||
        $err =~ /pgroup.*limit/i) {
        return "Pure FlashArray protection group limit reached. " .
               "Original error: $err";
    }

    # Capacity exhaustion (thin overcommit hitting physical limit, OR
    # provisioned capacity quota)
    if ($err =~ /no space|insufficient.*space|out.*of.*space|array.*full|capacity.*exceed/i) {
        return "Pure FlashArray is out of space. With thin provisioning, " .
               "this can happen even though individual volumes appear to " .
               "have free space — the physical array is full. Check Pure " .
               "UI > Storage > Array dashboard. Free up space by " .
               "destroying unused volumes (and waiting for eradication) " .
               "or expanding the array. Original error: $err";
    }

    # API rate limit
    if ($err =~ /429|rate.*limit|too many requests/i) {
        return "Pure FlashArray API rate limit hit (HTTP 429). The plugin " .
               "will back off and retry. If this happens repeatedly, you " .
               "may have many PVE nodes hitting the same array " .
               "simultaneously — consider increasing the API token's rate " .
               "quota in Pure UI > Settings > Users. Original error: $err";
    }

    # Pass through unknown errors unchanged.
    return $err;
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
        # Get pod-specific space (used capacity). The actual quota cap is
        # resolved separately via pod_get_quota_limit() because Pure has
        # two ways to set it (Pod.quota_limit field set by `purepod
        # --quota-limit` CLI, AND a Policy of type=quota whose `pod`
        # field references the pod) and only one of them shows up on
        # the pod object itself.
        $resp = eval { $self->pod_get($pod); };
        if ($@) {
            warn "Pure pod '$pod': cannot fetch pod info: $@";
            $resp = undef;
        }

        if (ref($resp) eq 'HASH' && $resp->{items}) {
            $space = $resp->{items}[0];
        } elsif (ref($resp) eq 'ARRAY' && $resp->[0]) {
            $space = $resp->[0];
        } else {
            $space = $resp;
        }

        my $quota = $self->pod_get_quota_limit($pod);

        my $used = 0;
        if (ref($space) eq 'HASH' && $space->{space}) {
            # Pod quota in Pure is enforced against `total_provisioned`
            # (sum of all volume sizes within the pod), NOT against
            # `virtual` (host-written bytes). To match what the array
            # actually enforces at allocation time — and to align with
            # the headline "Size" indicator Pure UI shows on the pod
            # detail page — prefer total_provisioned first here.
            #
            # History: a previous release briefly preferred `virtual`
            # first after a report of unexpected 100% readings. Closer
            # review showed those readings were semantically correct
            # (the pod contained a thin volume of its quota's size, so
            # total_provisioned == quota, and Pure would have refused
            # the next allocation in that state) and that aligning
            # with virtual was masking the legitimate allocation
            # ceiling. The total_provisioned-first ordering is the
            # correct match for what the array enforces.
            $used = $space->{space}{total_provisioned}
                 // $space->{space}{virtual}
                 // $space->{space}{total_physical}
                 // $space->{space}{total_used}
                 // 0;
        }

        if ($quota > 0) {
            my $avail = $quota - $used;
            $avail = 0 if $avail < 0;
            return {
                total     => $quota,
                used      => $used,
                available => $avail,
            };
        }
        # Fall through to array capacity if no quota policy attached
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

# Get effective quota_limit (in bytes) for a pod, by reading the Pod
# object's `quota_limit` field. This is the ONLY block-level quota
# mechanism Pure exposes for pods.
#
# IMPORTANT: do NOT confuse this with the Storage > Policies → quota
# Policy in the Pure GUI. That entire /policies/* family (autodir, nfs,
# smb, quota, snapshot) is FlashArray Files / managed-directory only,
# even when the policy's `pod` field points to a pod. Attaching such a
# policy to a pod does not create a block-level quota — it only marks
# the pod as having file-services policies attached, which causes Pure
# to reject every block volume create with the misleading error
# "Pod contains file systems or policies." (see CHANGELOG v1.1.12 and
# the README "Pod block quota" section).
#
# Block-level pod quota is set via:
#   - CLI: `purepod create --quota-limit` / `purepod setattr --quota-limit`
#   - REST: `PATCH /api/2.x/pods?names=X` body `{"quota_limit": N}`
#   - GUI: Storage > Pods > <pod> > Edit (Purity 6.6+ only; 6.5.x has no
#     GUI path)
#
# Returns 0 when no cap is set, the pod does not exist, the array runs
# API 1.x (pods are an API 2.x feature), or any error occurs. Never
# croaks — status() polling must not fail because of quota lookup.
sub pod_get_quota_limit {
    my ($self, $podname) = @_;

    return 0 unless defined $podname && length $podname;
    return 0 unless $self->is_api_v2();

    my $pod_resp = eval { $self->pod_get($podname); };
    return 0 if $@ || !$pod_resp;

    my $pod;
    if (ref($pod_resp) eq 'HASH' && ref($pod_resp->{items}) eq 'ARRAY') {
        $pod = $pod_resp->{items}[0];
    } elsif (ref($pod_resp) eq 'ARRAY') {
        $pod = $pod_resp->[0];
    } else {
        $pod = $pod_resp;
    }
    return 0 unless ref($pod) eq 'HASH';

    my $limit = $pod->{quota_limit};
    return 0 unless defined $limit;
    $limit = $limit + 0;
    return $limit > 0 ? $limit : 0;
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
        my $url = "volumes?names=$encoded_name";
        # When the volume is created inside a pod (name has "pod::" prefix),
        # disable Pure's automatic application of the pod's default
        # protection. Pure rejects the call with "Pod contains file
        # systems or policies." when a pod has any policy attached (e.g.
        # a quota policy created via Storage > Policies). PVE manages its
        # own protection policies via snapshots, so skipping the array-
        # side default protection here matches what we already assume
        # everywhere else and unblocks volume creation. Non-pod volumes
        # are left alone to preserve any user-configured array-level
        # default protection.
        if ($name =~ /::/) {
            $url .= "&with_default_protection=false";
        }
        return $self->post($url, {
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

# Delete a volume (requires 2 steps: destroy then eradicate).
# Volume destroy on Pure can be slow when the volume has many snapshots or
# is part of a pod with replication; use an extended 60s per-call timeout
# to avoid spurious "command timed out" warnings during normal operation.
#
# Pre-rename to tombstone before destroy (issue #8): Pure's destroyed-
# pending state reserves the volume's name for the array's eradication
# delay (default 24h). Without the rename, recreating a volume with the
# same name within that window fails. We rename the volume to
# "<orig>-pve-tomb-<unix-ts>-<pid>" first, so the original name is
# freed as soon as the rename succeeds; the tombstoned volume still
# goes into destroyed-pending (still recoverable from Pure UI, still
# eradicates on the array's normal schedule), just under the suffixed
# name. Operators can identify these tombstones in Pure's Destroyed
# Volumes list by the "-pve-tomb-" marker.
#
# Skip the rename when:
#   - caller explicitly passes tombstone => 0
#   - name already carries the tombstone marker (idempotent re-destroy
#     of a volume left tombstoned-but-alive by a previous failed call)
#   - resulting tombstone name would exceed Pure's 63-char volume-name
#     limit (truncating risks collision, better to accept the 24h
#     name reservation for this one volume)
sub volume_delete {
    my ($self, $name, %opts) = @_;

    croak "name is required" unless defined $name && length $name;

    my $do_tombstone = $opts{tombstone} // 1;
    my $renamed = 0;
    my $target_name = $name;

    if ($do_tombstone && $name !~ /-pve-tomb-\d+/) {
        my $tomb_name = _make_tombstone_name($name);
        if (defined $tomb_name) {
            my $rename_ok = eval { $self->volume_rename($name, $tomb_name); 1; };
            if ($rename_ok) {
                $target_name = $tomb_name;
                $renamed = 1;
            } else {
                # Rename failed (concurrent op, pod in reduced state,
                # permission issue, transient API error, etc). Fall
                # back to destroying with the original name — the
                # delete still succeeds, only the same-name immediate-
                # reuse benefit is lost for this one volume.
                my $err = $@;
                $err =~ s/\s+$//;
                warn "volume_delete: tombstone rename of '$name' " .
                     "failed; destroying under original name (Pure " .
                     "will hold this name until eradication delay). " .
                     "Underlying error: $err\n";
            }
        } else {
            warn "volume_delete: tombstone name for '$name' would " .
                 "exceed Pure's 63-char volume-name limit; destroying " .
                 "under original name (Pure will hold this name until " .
                 "eradication delay)\n";
        }
    }

    # Wrap the destroy phase so a failure can roll back the tombstone
    # rename. Without the rollback: a destroy failure after a successful
    # rename leaves the volume tombstoned-but-alive on Pure while the
    # PVE-side free_image throws — the operator's retry would look up
    # the original name, not find it (the volume is now under the
    # tombstone name), and fail again with a confusing "not found"
    # error. Rolling the name back restores the pre-call state so a
    # retry can run naturally. Rollback is best-effort: if it ALSO
    # fails (rare — implies array-wide issue like a degraded pod),
    # we log enough detail for the operator to clean up the
    # tombstoned-but-alive volume manually from Pure UI.
    my $destroy_ok = eval {
        if ($self->is_api_v2()) {
            # API 2.x: PATCH to destroy, then DELETE to eradicate
            $self->patch("volumes", { destroyed => JSON::true }, { names => $target_name }, timeout => 60);
            unless ($opts{skip_eradicate}) {
                $self->delete("volumes", { names => $target_name }, timeout => 60);
            }
        } else {
            # API 1.x
            $self->put("volume/$target_name", { destroyed => JSON::true }, timeout => 60);
            unless ($opts{skip_eradicate}) {
                $self->delete("volume/$target_name", undef, timeout => 60);
            }
        }
        1;
    };

    if (!$destroy_ok) {
        my $destroy_err = $@;

        if ($renamed) {
            my $rollback_ok = eval { $self->volume_rename($target_name, $name); 1; };
            unless ($rollback_ok) {
                my $rollback_err = $@;
                $rollback_err =~ s/\s+$//;
                warn "volume_delete: destroy of '$target_name' failed " .
                     "AND rollback rename to '$name' failed; the " .
                     "tombstoned-but-alive volume must be cleaned up " .
                     "manually from Pure (look for '$target_name' in " .
                     "Storage > Volumes). Rollback error: $rollback_err\n";
            }
        }

        $destroy_err =~ s/\s+$//;
        die "$destroy_err\n";
    }

    return 1;
}

# Build a tombstone name for pre-destroy rename. Returns undef if the
# resulting name would exceed Pure's 63-char volume-name limit (caller
# falls back to direct destroy in that case).
#
# Naming format: <orig>-pve-tomb-<unix-ts>-<pid>
#   - "-pve-tomb-" marker: operators can identify plugin-managed
#     tombstones in Pure's Destroyed Volumes list; plugin's regex
#     `/-pve-tomb-\d+/` recognises them to avoid recursive rename on
#     idempotent re-destroy.
#   - Unix timestamp (seconds): primary uniqueness.
#   - PID: secondary uniqueness — different PVE nodes deleting the
#     same volume concurrently get different PIDs, so they cannot
#     produce identical tombstone names in the same wall-clock second.
#
# Pod-prefixed volumes (e.g. "pod::pve-pure1-100-disk0") keep the
# "pod::" prefix on rename — Pure does not allow cross-pod renames.
# The 63-char limit applies to the post-"::" volume name portion.
sub _make_tombstone_name {
    my ($name) = @_;

    my ($prefix, $vol) = ('', $name);
    if ($name =~ /^([^:]+::)(.+)$/) {
        ($prefix, $vol) = ($1, $2);
    }

    my $suffix = "-pve-tomb-" . time() . "-$$";

    return undef if length($vol . $suffix) > 63;
    return "${prefix}${vol}${suffix}";
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
        my $url = "volumes?names=$encoded_name";
        # See volume_create for the with_default_protection rationale —
        # cloning into a pod with policies attached fails with the same
        # "Pod contains file systems or policies." error otherwise.
        if ($name =~ /::/) {
            $url .= "&with_default_protection=false";
        }
        return $self->post($url, {
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
        # API 2.x: POST /volumes?names=<target>&overwrite=true with source
        # in body. The original implementation used PATCH /volumes here,
        # but per the FA 2.x OpenAPI spec PATCH /volumes is the
        # rename/destroy/modify endpoint and does NOT accept `source` in
        # its body — Pure responds with "No attribute specified." and the
        # rollback silently no-ops on the volume contents (the PVE side
        # task still reports success because the API returned 200 with an
        # empty body). The copy-and-overwrite operation is the same POST
        # endpoint as volume_clone, with the `overwrite=true` query
        # parameter that the spec defines for the "object copy operation"
        # case. Note: per spec, `add_to_protection_group_names` and
        # `with_default_protection` MUST NOT be supplied when overwrite
        # is true, so this path deliberately omits them.
        #
        # Reported by @tgdfama1 (#1) and @pulipulichen (#2).
        my $encoded_name = uri_escape($name);
        return $self->post("volumes?names=$encoded_name&overwrite=true", {
            source => { name => $source },
        });
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

# Rename a snapshot. Per the FA 2.x spec, the body `name` field on
# PATCH /volume-snapshots is the new SUFFIX only (not the full name);
# the source volume association is preserved. The full name on Pure
# after rename is `<source_volume_name>.<new_suffix>`.
sub snapshot_rename {
    my ($self, $old_full_name, $new_suffix) = @_;

    croak "old_full_name is required" unless defined $old_full_name && length $old_full_name;
    croak "new_suffix is required" unless defined $new_suffix && length $new_suffix;

    if ($self->is_api_v2()) {
        return $self->patch("volume-snapshots", { name => $new_suffix }, { names => $old_full_name });
    } else {
        # API 1.x: snapshot rename not exposed via REST in older releases;
        # caller must skip the tombstone path on API 1.x.
        croak "snapshot_rename is not supported on API 1.x";
    }
}

# Build the new (suffix-only) tombstone name for a snapshot pre-destroy
# rename. Mirrors _make_tombstone_name for volumes but lives on the
# snapshot suffix portion so the volume association stays clear in
# Pure UI. Returns ($source_vol_name, $new_suffix) on success,
# (undef, undef) when the rename would exceed Pure's 64-char suffix
# limit and the caller should fall back to a direct destroy.
sub _make_snapshot_tombstone {
    my ($full_name) = @_;

    # Plugin-managed snapshot full name format is "<volname>.<suffix>"
    # (the volname portion may itself contain "pod::" prefix). Split on
    # the FIRST "." since PVE-encoded volume names never contain a dot
    # (sanitize_for_pure strips dots; storeid_to_pure_prefix is
    # symmetric).
    my $dot_idx = index($full_name, '.');
    return (undef, undef) if $dot_idx < 0;
    my $vol_part    = substr($full_name, 0, $dot_idx);
    my $suffix_part = substr($full_name, $dot_idx + 1);
    return (undef, undef) unless length $suffix_part;

    my $tomb_addition = "-pve-tomb-" . time() . "-$$";
    my $new_suffix = $suffix_part . $tomb_addition;

    # Pure's snapshot suffix length cap is 64 chars (matches the
    # plugin's MAX_SNAPSHOT_SUFFIX_LENGTH). If we'd overrun, return
    # undef and let the caller destroy under the original name.
    return (undef, undef) if length($new_suffix) > 64;

    return ($vol_part, $new_suffix);
}

# Delete a snapshot.
#
# Pre-rename to tombstone before destroy (issue #11, mirrors the
# volume-side fix in #8 / v1.1.15). Pure's destroyed-pending state
# reserves the snapshot's name until the array's eradication delay
# (default 24h). Without the rename, recreating a snapshot with the
# same suffix within that window fails with "Snapshot already exists
# for volume". The pre-rename moves the destroyed snapshot under a
# different suffix so the original suffix is freed immediately.
#
# Skip tombstone when:
#   - caller passes tombstone => 0
#   - the suffix already carries the tombstone marker (idempotent
#     re-destroy of a previously-failed delete)
#   - the resulting suffix would exceed Pure's 64-char snapshot
#     suffix limit
#   - the array is on API 1.x (snapshot_rename not supported there)
sub snapshot_delete {
    my ($self, $snapname, %opts) = @_;

    croak "snapshot name is required" unless defined $snapname && length $snapname;

    my $do_tombstone = $opts{tombstone} // 1;
    my $renamed = 0;
    my $orig_suffix;    # for rollback
    my $target_name = $snapname;

    if ($do_tombstone && $self->is_api_v2() && $snapname !~ /-pve-tomb-\d+/) {
        my ($vol_part, $new_suffix) = _make_snapshot_tombstone($snapname);
        if (defined $new_suffix) {
            # Remember the original suffix so we can roll the rename
            # back if the subsequent destroy fails.
            my $dot_idx = index($snapname, '.');
            $orig_suffix = substr($snapname, $dot_idx + 1);

            my $rename_ok = eval { $self->snapshot_rename($snapname, $new_suffix); 1; };
            if ($rename_ok) {
                $target_name = "$vol_part.$new_suffix";
                $renamed = 1;
            } else {
                my $err = $@;
                $err =~ s/\s+$//;
                warn "snapshot_delete: tombstone rename of '$snapname' " .
                     "failed; destroying under original name (the snapshot " .
                     "suffix will be reserved by Pure until eradication " .
                     "delay expires). Underlying error: $err\n";
            }
        } else {
            warn "snapshot_delete: tombstone suffix for '$snapname' would " .
                 "exceed Pure's 64-char snapshot-suffix limit; destroying " .
                 "under original name (the snapshot suffix will be reserved " .
                 "by Pure until eradication delay expires)\n";
        }
    }

    my $destroy_ok = eval {
        if ($self->is_api_v2()) {
            $self->patch("volume-snapshots", { destroyed => JSON::true }, { names => $target_name });
            unless ($opts{skip_eradicate}) {
                $self->delete("volume-snapshots", { names => $target_name });
            }
        } else {
            $self->put("volume/$target_name", { destroyed => JSON::true });
            unless ($opts{skip_eradicate}) {
                $self->delete("volume/$target_name");
            }
        }
        1;
    };

    if (!$destroy_ok) {
        my $destroy_err = $@;

        if ($renamed && defined $orig_suffix) {
            # Best-effort rollback so a retry can find the snapshot
            # under its original name.
            my $rollback_ok = eval { $self->snapshot_rename($target_name, $orig_suffix); 1; };
            unless ($rollback_ok) {
                my $rollback_err = $@;
                $rollback_err =~ s/\s+$//;
                warn "snapshot_delete: destroy of '$target_name' failed " .
                     "AND rollback rename to suffix '$orig_suffix' " .
                     "failed; the tombstoned-but-alive snapshot must be " .
                     "cleaned up manually from Pure (look for " .
                     "'$target_name'). Rollback error: $rollback_err\n";
            }
        }

        $destroy_err =~ s/\s+$//;
        die "$destroy_err\n";
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
        # API 1.x: GET /volume/<vol>/host
        $resp = eval { $self->get("volume/$volume/host"); };
    }
    return [] if $@;
    return [] unless $resp;

    # Normalise to a single shape regardless of API version. Callers expect
    # `[ { name => "<host_name>" }, ... ]` so they can do `$conn->{name}`.
    #
    # API 2.x raw shape:
    #   { items => [ { host => { name => "h1" }, host_name => "h1", ... } ] }
    # API 1.x raw shape (from /volume/<vol>/host):
    #   [ { "host" => "h1", "lun" => 1, "name" => "myvolume" } ]
    # Note that on 1.x the `name` field is the VOLUME name, NOT the host
    # name. Without this normalisation, `$conn->{name}` returned the volume
    # name and every `volume_disconnect_host` call became a no-op, leaving
    # orphaned host connections forever.

    if (ref($resp) eq 'HASH' && $resp->{items}) {
        return [
            map { { name => $_->{host}{name} // $_->{host_name} } }
            @{ $resp->{items} }
        ];
    }
    if (ref($resp) eq 'ARRAY') {
        return [
            map {
                {
                    name => (
                        ref($_) eq 'HASH'
                            ? ( $_->{host} // $_->{host_name} // $_->{name} )
                            : $_
                    )
                }
            } @$resp
        ];
    }
    return [];
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
