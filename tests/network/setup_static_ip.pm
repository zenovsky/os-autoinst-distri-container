# openQA test
#
# Summary: Shared precondition for multi-machine network tests —
# static IPv4 address, gateway and DNS on a secondary interface,
# followed by an optional ping of the peer.
#
# Role-agnostic: the same module is scheduled on every machine of the job
# group; the address comes from the job variables, not from the role.
#
# Variables:
#   STATIC_IP       (required) address of this machine, e.g. 172.16.2.10
#   STATIC_PREFIX   prefix length, default 15
#   STATIC_GATEWAY  default 172.16.2.2
#   DNS_IP          nameserver; DNS is not configured if unset
#   NET_IFACE       interface name, default ens4
#   NET_CON_NAME    NetworkManager connection name, default ens4-static
#   PEER_IP         if set, the peer is pinged after the setup
use Mojo::Base 'basetest';
use utf8;
use testapi;
use StepReport;

# Without a working network the dependent tests are meaningless, so stop the job here.
sub test_flags { return {fatal => 1} }

sub run {
    my $ip = get_var('STATIC_IP') or die "STATIC_IP is not set\n";
    my $prefix = get_var('STATIC_PREFIX', '15');
    my $gateway = get_var('STATIC_GATEWAY', '172.16.2.2');
    my $dns = get_var('DNS_IP');
    my $iface = get_var('NET_IFACE', 'ens4');
    my $con = get_var('NET_CON_NAME', 'ens4-static');
    my $peer = get_var('PEER_IP');

    step 'Предусловие. Настройка сети' => sub {
        # Idempotent: a leftover connection from a previous run would make "con add" fail
        run_cmd "Removing a stale connection $con if present" => "nmcli con delete $con || true";

        my $add = "nmcli con add type ethernet ifname $iface con-name $con "
          . "ipv4.addresses $ip/$prefix ipv4.gateway $gateway ipv4.method manual";
        $add .= " ipv4.dns $dns" if $dns;
        run_cmd "Adding static connection $con ($ip/$prefix, gateway $gateway" . ($dns ? ", DNS $dns" : '') . ')' => $add;

        # Fail early with a clear message if the NIC is missing, instead of waiting for the NM timeout
        run_cmd "Checking that interface $iface exists" => "ip link show $iface";

        my $ok = eval {
            run_cmd "Activating connection $con" => "nmcli -w 30 con up $con", timeout => 60;
            1;
        };
        my $err = $@;
        unless ($ok) {
            # Collect the facts needed to tell "no carrier" from "wrong NIC" from "conflicting profile"
            probe_cmd 'Diagnostics: link state of all interfaces' => 'ip -br link';
            probe_cmd 'Diagnostics: addresses' => 'ip -br addr';
            probe_cmd 'Diagnostics: NetworkManager devices' => 'nmcli -f DEVICE,TYPE,STATE,CONNECTION device status';
            probe_cmd "Diagnostics: carrier of $iface (1 = link up)" => "cat /sys/class/net/$iface/carrier";
            probe_cmd 'Diagnostics: NetworkManager journal' => 'journalctl -u NetworkManager -n 40 --no-pager';
            die $err;
        }

        run_cmd "Checking that $iface has the address $ip" => "ip -4 addr show $iface | grep -w 'inet $ip/$prefix'";

        run_cmd "Setting nameserver $dns in /etc/resolv.conf" => "echo 'nameserver $dns' > /etc/resolv.conf" if $dns;
    };

    if ($peer) {
        step 'Предусловие. Сетевая связанность с соседней машиной (ping)' => sub {
            run_cmd "Checking connectivity to the peer $peer (4 ICMP echo requests)" => "ping -c 4 $peer";
        };
    }
}

sub post_fail_hook { write_step_report('network-setup', failed => 1) }

1;
