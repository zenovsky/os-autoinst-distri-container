# openQA test
#
# Summary: OpenSSH (Server) — installation, configuration, service restart,
# system reboot, package update.
# Source:
# Paired module: ssh_client.pm — runs on a second machine in the same
# job group:
# TEST=openssh
use Mojo::Base 'basetest';
use testapi;
use lockapi;
use mmapi;
use utils;
use StepReport;

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

sub run {
    add_step_secret($test_pass);

    barrier_create "net_ready", 2;
    barrier_create "user_ready", 2;
    barrier_create "package_ready", 2;
    barrier_create "client_key_installed", 2;
    barrier_create "client_key_checks_done", 2;
    barrier_create "server_sshd_restarted", 2;
    barrier_create "server_rebooted", 2;
    barrier_create "client_post_reboot_done", 2;
    barrier_create "server_updated", 2;
    barrier_create "client_final_checks_done", 2;

    # --- Preconditions ---
    step 'Precondition. Network setup' => sub {
        run_cmd "Adding static connection ens4-static ($server_ip/15, gateway 172.16.2.2, DNS $dns_ip)" =>
          "nmcli con add type ethernet ifname ens4 con-name ens4-static "
          . "ipv4.addresses $server_ip/15 ipv4.gateway 172.16.2.2 "
          . "ipv4.dns $dns_ip ipv4.method manual";
        run_cmd "Activating connection ens4-static" => "nmcli con up ens4-static";
        run_cmd "Setting nameserver $dns_ip in /etc/resolv.conf" => "echo 'nameserver $dns_ip' > /etc/resolv.conf";
    };

    barrier_wait "net_ready";

    step 'Precondition. Ping client' => sub {
        run_cmd "Checking connectivity to the client $client_ip (4 ICMP echo requests)" => "ping -c 4 $client_ip";
    };

    step 'Precondition. Create test user' => sub {
        run_cmd "Creating user $test_user with shell /bin/bash" => "useradd -m -s /bin/bash $test_user";
        run_cmd "Setting the password for $test_user" => "echo '$test_user:$test_pass' | chpasswd";
        run_cmd "Opening permissions on /dev/ttyS0 (chmod 777)" => "chmod 777 /dev/ttyS0";
    };

    barrier_wait "user_ready";

    # --- Step 1: Install the package ---
    step 'Step 1. Install the package' => sub {
        run_cmd "Installing the openssh package with dnf" => "dnf install -y openssh", timeout => 300, quiet => 1;
    };

    # --- Step 2: sshd port configuration ---
    step 'Step 2. sshd port configuration' => sub {
        run_cmd "Checking that the effective sshd configuration uses port 22" => "sshd -T | grep 'port 22'";
    };

    # --- Step 3: Start the service ---
    step 'Step 3. Start the service' => sub {
        run_cmd "Starting the sshd service" => "systemctl start sshd";
        run_cmd "Checking that the sshd service is active" => "systemctl is-active sshd";
    };

    # --- Step 4: Enable sshd autostart ---
    step 'Step 4. Enable sshd autostart' => sub {
        run_cmd "Enabling the sshd service at boot and starting it now" => "systemctl enable --now sshd";
        run_cmd "Checking that the sshd service is enabled" => "systemctl is-enabled sshd";
    };

    # --- Step 5: Listening port ---
    step 'Step 5. sshd listens on port 22' => sub {
        run_cmd "Checking that something listens on TCP port 22" => "ss -lntp | grep ':22'";
    };

    # --- Step 6: firewalld ---
    step 'Step 6. Firewall allows ssh' => sub {
        run_cmd "Checking that firewalld allows the ssh service" => "firewall-cmd --list-services | grep 'ssh'";
    };

    barrier_wait "package_ready";
    barrier_wait "client_key_installed";
    barrier_wait "client_key_checks_done";

    # --- Step 7: Restart the sshd service ---
    step 'Step 7. Restart the sshd service' => sub {
        run_cmd "Restarting the sshd service" => "systemctl restart sshd";
        run_cmd "Checking that the sshd service is active after the restart" => "systemctl is-active sshd";
    };

    barrier_wait "server_sshd_restarted";

    # --- Step 8: Server reboot ---
    step 'Step 8. Reboot and verify sshd' => sub {
        step_log "Rebooting the server and waiting for the console login";
        reboot();
        run_cmd "Checking that the sshd service is active after the reboot" => "systemctl is-active sshd";
    };

    barrier_wait "server_rebooted";
    barrier_wait "client_post_reboot_done";

    # --- Step 9: checking/installing the package update ---
    step 'Step 9. Check and install the package update' => sub {
        my ($rc, $out) = probe_cmd "Checking for an openssh update (dnf check-update)" => "dnf check-update openssh", timeout => 300;
        if ($rc == 100) {
            run_cmd "An update is available, installing it with dnf update" => "dnf update -y openssh", timeout => 300, quiet => 1;
        }
        elsif ($rc != 0) {
            die "dnf check-update failed with exit code $rc:\n$out";
        }
        run_cmd "Checking that the sshd service is active after the update" => "systemctl is-active sshd";
    }; 

    barrier_wait "server_updated";
    barrier_wait "client_final_checks_done";

    # --- Step 10: Checking logs for errors ---
    step 'Step 10. Check logs for errors' => sub {
        step_log "Reading the last 100 lines of the sshd journal";
        my $logs = script_output "journalctl -u sshd --no-pager -n 100";
        step_log "Checking the journal for 'Failed', 'fatal' or 'error' entries";
        die "sshd logs contain errors:\n$logs"
          if $logs =~ /Failed|fatal|error/i;
    };

    # --- Step 11: General status of the OS ---
    step 'Step 11. General status of the OS' => sub {
        run_cmd "Verifying the openssh package files (rpm -V)" => "rpm -V openssh", quiet => 1;
        run_cmd "Checking the package database consistency (dnf check)" => "dnf check";
        run_cmd "Checking that SELinux is in Enforcing mode" => "getenforce | grep 'Enforcing'";
        run_cmd "Checking that port 22 is still listening" => "ss -lntp | grep ':22'";
        run_cmd "Printing the kernel command line" => "cat /proc/cmdline";
        run_cmd "Checking that there are no failed systemd units" => "systemctl --failed | grep '0 loaded units listed'";
    };
}

sub post_fail_hook { write_step_report('ssh_server', failed => 1) }
sub post_run_hook  { write_step_report('ssh_server') }

1;