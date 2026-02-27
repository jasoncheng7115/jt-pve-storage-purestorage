# Pure Storage Naming Convention Utilities
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::PureStorage::Naming;

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(
    encode_volume_name
    decode_volume_name
    encode_snapshot_name
    decode_snapshot_name
    encode_host_name
    encode_config_volume_name
    decode_config_volume_name
    is_config_volume
    sanitize_for_pure
    is_valid_pure_volume_name
    is_pve_managed_volume
    pve_volname_to_pure
    pure_to_pve_volname
);

# Pure Storage naming constraints
# Volume names: 1-63 characters, alphanumeric, hyphen, underscore
# Must start with alphanumeric
use constant {
    MAX_VOLUME_NAME_LENGTH   => 63,
    MAX_SNAPSHOT_SUFFIX_LENGTH => 64,
    MAX_HOST_NAME_LENGTH     => 63,
    MAX_STORAGE_NAME_LENGTH  => 24,
};

# Regex patterns for parsing
# Pure volume: pve-{storage}-{vmid}-disk{diskid}
# Storage name portion uses non-greedy .+? to support names with hyphens
# (backwards compat). New volumes always use underscores in storage portion.
# Unambiguous because VMID is always pure digits anchored by -disk{N}$ suffix.
my $RE_VOLUME_NAME = qr/^pve-(.+?)-(\d+)-disk(\d+)$/;
my $RE_CLOUDINIT   = qr/^pve-(.+?)-(\d+)-cloudinit$/;
my $RE_VMSTATE     = qr/^pve-(.+?)-(\d+)-state-(.+)$/;
# Snapshot: {volume}.pve-snap-{snapname}
my $RE_SNAPSHOT    = qr/^(.+)\.pve-snap-(.+)$/;
# VM Config backup: pve-{storage}-{vmid}-vmconf-{snapname}
my $RE_VMCONF      = qr/^pve-(.+?)-(\d+)-vmconf-(.+)$/;

# Sanitize a string for Pure Storage naming rules
sub sanitize_for_pure {
    my ($str, $max_len) = @_;
    $max_len //= MAX_VOLUME_NAME_LENGTH;

    return '' unless defined $str && length($str) > 0;

    my $sanitized = $str;
    # Replace spaces with hyphens
    $sanitized =~ s/\s+/-/g;
    # Remove any character that's not alphanumeric, hyphen, or underscore
    $sanitized =~ s/[^a-zA-Z0-9_-]//g;
    # Ensure it starts with alphanumeric
    $sanitized =~ s/^[^a-zA-Z0-9]+//;
    # Ensure it doesn't end with hyphen or underscore
    $sanitized =~ s/[-_]+$//;
    # Truncate to max length
    $sanitized = substr($sanitized, 0, $max_len);
    # Ensure not empty after sanitization
    $sanitized = 'pve' unless length($sanitized) > 0;

    return $sanitized;
}

# Encode PVE volume identifier to Pure Storage volume name
# Input: storage ID, VM ID, disk ID
# Output: Pure volume name like "pve-pure1-100-disk0"
sub encode_volume_name {
    my ($storage, $vmid, $diskid) = @_;

    die "storage is required" unless defined $storage;
    die "vmid is required" unless defined $vmid;
    die "diskid is required" unless defined $diskid;

    my $san_storage = sanitize_for_pure($storage, MAX_STORAGE_NAME_LENGTH);
    # Replace hyphens with underscores in storage portion to avoid parsing
    # ambiguity in decode_volume_name (hyphens are used as field separators)
    $san_storage =~ s/-/_/g;
    return "pve-${san_storage}-${vmid}-disk${diskid}";
}

# Decode Pure Storage volume name to PVE components
# Returns hashref: { storage => ..., vmid => ..., diskid => ... }
# Returns undef if name doesn't match expected pattern
sub decode_volume_name {
    my ($volname) = @_;

    return undef unless defined $volname;

    # Skip snapshots (contain dot)
    return undef if $volname =~ /\./;

    # Standard disk
    if ($volname =~ $RE_VOLUME_NAME) {
        return {
            storage => $1,
            vmid    => int($2),
            diskid  => int($3),
            type    => 'disk',
        };
    }

    # Cloud-init
    if ($volname =~ $RE_CLOUDINIT) {
        return {
            storage => $1,
            vmid    => int($2),
            type    => 'cloudinit',
        };
    }

    # VM state
    if ($volname =~ $RE_VMSTATE) {
        return {
            storage  => $1,
            vmid     => int($2),
            snapname => $3,
            type     => 'state',
        };
    }

    return undef;
}

# Encode PVE snapshot name to Pure Storage snapshot suffix
# Pure snapshot format: {volume}.{suffix}
#
# Pure Storage snapshot suffix restrictions:
#   - Only alphanumeric and '-' allowed (NO underscores!)
#   - Must be 1-63 characters
#   - Must begin and end with letter or number
#   - Must include at least one letter or '-'
#
# WARNING: This is a lossy conversion! Names like 'test_1' and 'test-1'
#          will both become 'pve-snap-test-1'. The original name cannot
#          be perfectly restored.
#
sub encode_snapshot_name {
    my ($snapname) = @_;

    die "snapshot name is required" unless defined $snapname;

    # Sanitize for Pure Storage snapshot suffix (stricter than volume names)
    my $san_snap = $snapname;
    # Replace underscores and dots with dashes (Pure doesn't allow them in suffix)
    $san_snap =~ s/[_.]/-/g;
    # Replace spaces with dashes
    $san_snap =~ s/\s+/-/g;
    # Remove any character that's not alphanumeric or dash
    $san_snap =~ s/[^a-zA-Z0-9-]//g;
    # Collapse multiple dashes
    $san_snap =~ s/-+/-/g;
    # Ensure it starts with alphanumeric
    $san_snap =~ s/^[^a-zA-Z0-9]+//;
    # Ensure it doesn't end with dash
    $san_snap =~ s/-+$//;
    # Truncate to max length (suffix max 64, minus 'pve-snap-' prefix = 55)
    $san_snap = substr($san_snap, 0, MAX_SNAPSHOT_SUFFIX_LENGTH - 10);
    # Ensure not empty after all sanitization
    $san_snap = 'snap' unless length($san_snap) > 0;

    return "pve-snap-${san_snap}";
}

# Decode Pure Storage snapshot name to PVE snapshot name
# Input: full snapshot name like "pve-pure1-100-disk0.pve-snap-backup1"
# Returns: { volume => ..., snapname => ... } or undef
sub decode_snapshot_name {
    my ($pure_snapname) = @_;

    return undef unless defined $pure_snapname;

    if ($pure_snapname =~ $RE_SNAPSHOT) {
        return {
            volume   => $1,
            snapname => $2,
        };
    }

    return undef;
}

# Encode host name for a PVE node
sub encode_host_name {
    my ($cluster, $node) = @_;

    $cluster //= 'pve';
    my $san_cluster = sanitize_for_pure($cluster, 20);

    if (defined $node) {
        my $san_node = sanitize_for_pure($node, 20);
        return "pve-${san_cluster}-${san_node}";
    } else {
        return "pve-${san_cluster}-shared";
    }
}

# Encode VM config backup volume name
# Format: pve-{storage}-{vmid}-vmconf-{snapname}
sub encode_config_volume_name {
    my ($storage, $vmid, $snapname) = @_;

    die "storage is required" unless defined $storage;
    die "vmid is required" unless defined $vmid;
    die "snapname is required" unless defined $snapname;

    my $san_storage = sanitize_for_pure($storage, MAX_STORAGE_NAME_LENGTH);
    $san_storage =~ s/-/_/g;
    my $san_snap = sanitize_for_pure($snapname, 30);
    my $result = "pve-${san_storage}-${vmid}-vmconf-${san_snap}";

    # Truncate snapname portion if total exceeds Pure Storage limit
    if (length($result) > MAX_VOLUME_NAME_LENGTH) {
        my $prefix = "pve-${san_storage}-${vmid}-vmconf-";
        my $max_snap = MAX_VOLUME_NAME_LENGTH - length($prefix);
        $san_snap = substr($san_snap, 0, $max_snap) if $max_snap > 0;
        $san_snap =~ s/[-_]+$//;  # Clean trailing separators after truncation
        $result = "${prefix}${san_snap}";
    }

    return $result;
}

# Decode VM config backup volume name
# Returns hashref: { storage => ..., vmid => ..., snapname => ... }
sub decode_config_volume_name {
    my ($volname) = @_;

    return undef unless defined $volname;

    if ($volname =~ $RE_VMCONF) {
        return {
            storage  => $1,
            vmid     => int($2),
            snapname => $3,
            type     => 'vmconf',
        };
    }

    return undef;
}

# Check if volume name is a VM config backup volume
sub is_config_volume {
    my ($volname) = @_;

    return 0 unless defined $volname;
    return ($volname =~ $RE_VMCONF) ? 1 : 0;
}

# Validate Pure Storage volume name
sub is_valid_pure_volume_name {
    my ($name) = @_;

    return 0 unless defined $name;
    return 0 if length($name) > MAX_VOLUME_NAME_LENGTH;
    return 0 if length($name) < 1;
    # Must start with alphanumeric
    return 0 unless $name =~ /^[a-zA-Z0-9]/;
    # Only alphanumeric, hyphen, underscore allowed
    return 0 unless $name =~ /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;

    return 1;
}

# Check if volume name is managed by this plugin
sub is_pve_managed_volume {
    my ($name) = @_;

    return 0 unless defined $name;
    return ($name =~ /^pve-.+?-\d+-(disk\d+|cloudinit|state-.+)$/);
}

# Convert PVE volume name (vm-100-disk-0 or base-100-disk-0) to Pure volume name
sub pve_volname_to_pure {
    my ($storage, $pve_volname) = @_;

    die "storage is required" unless defined $storage;
    die "pve_volname is required" unless defined $pve_volname;

    # Linked clone format: base-102-disk-0/vm-104-disk-0
    # Extract the actual volume name (the part after /)
    if ($pve_volname =~ m|^base-\d+-disk-\d+/(vm-(\d+)-disk-(\d+))$|) {
        return encode_volume_name($storage, $2, $3);
    }

    # Parse PVE volume name format: vm-{vmid}-disk-{diskid}
    if ($pve_volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return encode_volume_name($storage, $1, $2);
    }

    # Template base disk: base-{vmid}-disk-{diskid}
    if ($pve_volname =~ /^base-(\d+)-disk-(\d+)$/) {
        return encode_volume_name($storage, $1, $2);
    }

    # Cloud-init: vm-{vmid}-cloudinit
    if ($pve_volname =~ /^vm-(\d+)-cloudinit$/) {
        my $vmid = $1;
        my $san_storage = sanitize_for_pure($storage, MAX_STORAGE_NAME_LENGTH);
        $san_storage =~ s/-/_/g;
        return "pve-${san_storage}-${vmid}-cloudinit";
    }

    # VM state: vm-{vmid}-state-{snapname}
    if ($pve_volname =~ /^vm-(\d+)-state-(.+)$/) {
        my ($vmid, $snapname) = ($1, $2);
        my $san_storage = sanitize_for_pure($storage, MAX_STORAGE_NAME_LENGTH);
        $san_storage =~ s/-/_/g;
        my $san_snap = sanitize_for_pure($snapname, 30);
        return "pve-${san_storage}-${vmid}-state-${san_snap}";
    }

    die "Unrecognized PVE volume name format: $pve_volname";
}

# Convert Pure volume name to PVE volume name
sub pure_to_pve_volname {
    my ($pure_volname) = @_;

    my $decoded = decode_volume_name($pure_volname);
    return undef unless $decoded;

    if ($decoded->{type} eq 'disk') {
        return "vm-$decoded->{vmid}-disk-$decoded->{diskid}";
    } elsif ($decoded->{type} eq 'cloudinit') {
        return "vm-$decoded->{vmid}-cloudinit";
    } elsif ($decoded->{type} eq 'state') {
        return "vm-$decoded->{vmid}-state-$decoded->{snapname}";
    }

    return undef;
}

# Get full snapshot name (volume.suffix)
sub get_full_snapshot_name {
    my ($volume, $snapname) = @_;

    my $suffix = encode_snapshot_name($snapname);
    return "${volume}.${suffix}";
}

# Parse full snapshot name to components
sub parse_full_snapshot_name {
    my ($full_name) = @_;

    return decode_snapshot_name($full_name);
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::PureStorage::Naming - Naming convention utilities for Pure Storage plugin

=head1 SYNOPSIS

    use PVE::Storage::Custom::PureStorage::Naming qw(
        encode_volume_name
        decode_volume_name
        encode_snapshot_name
    );

    # Encode PVE disk to Pure volume name
    my $volname = encode_volume_name('pure1', 100, 0);
    # Returns: pve-pure1-100-disk0

    # Decode Pure volume name
    my $info = decode_volume_name('pve-pure1-100-disk0');
    # Returns: { storage => 'pure1', vmid => 100, diskid => 0, type => 'disk' }

=head1 DESCRIPTION

This module provides naming convention utilities for mapping between
Proxmox VE volume names and Pure Storage FlashArray object names.

=head1 NAMING PATTERNS

=over 4

=item Volume: C<pve-{storage}-{vmid}-disk{diskid}>

=item Snapshot: C<{volume}.pve-snap-{snapname}>

=item Host: C<pve-{cluster}-{node}> or C<pve-{cluster}-shared>

=back

=cut
