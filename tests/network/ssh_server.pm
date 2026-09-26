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
        run_cmd "Installing the openssh package with dnf" => "dnf install -y openssh", timeout => 300;
    };

    # --- Step 2: sshd configuration ---
    step 'Step 2. sshd configuration' => sub {
        run_cmd "Checking that the effective sshd configuration uses port 22" => "sshd -T | grep 'port 22'";
    };

    # --- Step 3: Start the service ---
    step 'Step 3. Start the service' => sub {
        run_cmd "Starting the sshd service" => "systemctl start sshd";
        run_cmd "Checking that the sshd service is active" => "systemctl is-active sshd";
    };

    # --- Step 4: Autoload ---
    step 'Step 4. Autoload' => sub {
        run_cmd "Enabling the sshd service at boot and starting it now" => "systemctl enable --now sshd";
        run_cmd "Checking that the sshd service is enabled" => "systemctl is-enabled sshd";
    };

    # --- Step 5: Listening port ---
    step 'Step 5. Listening port' => sub {
        run_cmd "Checking that something listens on TCP port 22" => "ss -lntp | grep ':22'";
    };

    # --- Step 6: firewalld ---
    step 'Step 6. firewalld' => sub {
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
    step 'Step 8. Server reboot' => sub {
        step_log "Rebooting the server and waiting for the console login";
        reboot();
    };

    # --- Step 9: Service is active after reboot ---
    step 'Step 9. Service is active after reboot' => sub {
        run_cmd "Checking that the sshd service is active after the reboot" => "systemctl is-active sshd";
    };

    barrier_wait "server_rebooted";
    barrier_wait "client_post_reboot_done";

    # # --- Step 10: checking/installing the package update ---
    # step 'Step 10. Check and install the package update' => sub {
    #     step_log "Checking for an openssh update (dnf check-update)";
    #     my $rc = script_run("dnf check-update openssh", timeout => 300) // -1;
    #     step_log "dnf check-update finished with exit code $rc (0 = up to date, 100 = update available, -1 = timeout)";
    #     if ($rc == 100) {
    #         run_cmd "An update is available, installing it with dnf update" => "dnf update -y openssh", timeout => 300;
    #     }
    #     elsif ($rc != 0) {
    #         die "dnf check-update failed with code $rc";
    #     }
    # };

    # --- Step 10: checking/installing the package update ---
    step 'Step 10. Check and install the package update' => sub {
        my ($rc, $out) = probe_cmd "Checking for an openssh update (dnf check-update)" => "dnf check-update openssh", timeout => 300;
        if ($rc == 100) {
            run_cmd "An update is available, installing it with dnf update" => "dnf update -y openssh", timeout => 300, quiet => 1;
        }
        elsif ($rc != 0) {
            die "dnf check-update failed with exit code $rc:\n$out";
        }
    }; 

    # --- Step 11: Service active after update ---
    step 'Step 11. Service is active after update' => sub {
        run_cmd "Checking that the sshd service is active after the update" => "systemctl is-active sshd";
    };

    barrier_wait "server_updated";
    barrier_wait "client_final_checks_done";

    # --- Step 12: Checking logs for errors ---
    step 'Step 12. Check logs for errors' => sub {
        step_log "Reading the last 100 lines of the sshd journal";
        my $logs = script_output "journalctl -u sshd --no-pager -n 100";
        step_log "Checking the journal for 'Failed', 'fatal' or 'error' entries";
        die "sshd logs contain errors:\n$logs"
          if $logs =~ /Failed|fatal|error/i;
    };

    # --- Step 13: General status of the OS ---
    step 'Step 13. General status of the OS' => sub {
        run_cmd "Verifying the openssh package files (rpm -V)" => "rpm -V openssh", quiet => 1;
        run_cmd "Checking the package database consistency (dnf check)" => "dnf check";
        run_cmd "Checking that SELinux is in Enforcing mode" => "getenforce | grep 'Enforcing'";
        run_cmd "Checking that port 22 is still listening" => "ss -lntp | grep ':22'";
        run_cmd "Printing the kernel command line" => "cat /proc/cmdline";
        run_cmd "Checking that there are no failed systemd units" => "systemctl --failed | grep '0 loaded units listed'";
    };
}

# A report is written whether there is success or failure.
sub post_fail_hook { write_step_report('ssh_server', failed => 1) }
sub post_run_hook  { write_step_report('ssh_server') }

1;

# # openQA test
# #
# # Summary: OpenSSH (Server) — installation, configuration, service restart,
# # system reboot, package update.
# # Source:
# # Paired module: ssh_client.pm — runs on a second machine in the same
# # job group:
# # TEST=openssh
# use Mojo::Base 'basetest';
# use testapi;
# use lockapi;
# use mmapi;
# use utils;
# use StepReport;

# my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
# my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
# my $dns_ip = get_var('DNS_IP');

# my $test_user = get_var('SSH_USER', 'ssh_test_user');
# my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

# sub run {
#     add_step_secret($test_pass);

#     barrier_create "net_ready", 2;
#     barrier_create "user_ready", 2;
#     barrier_create "package_ready", 2;
#     barrier_create "client_key_installed", 2;
#     barrier_create "client_key_checks_done", 2;
#     barrier_create "server_sshd_restarted", 2;
#     barrier_create "server_rebooted", 2;
#     barrier_create "client_post_reboot_done", 2;
#     barrier_create "server_updated", 2;
#     barrier_create "client_final_checks_done", 2;
 
#     # --- Preconditions ---
#     step 'P1. Network setup' => sub {
#         step_log "Adding static connection ens4-static ($server_ip/15, gateway 172.16.2.2, DNS $dns_ip)";
#         assert_script_run "nmcli con add type ethernet ifname ens4 con-name ens4-static "
#           . "ipv4.addresses $server_ip/15 ipv4.gateway 172.16.2.2 "
#           . "ipv4.dns $dns_ip ipv4.method manual";
#         step_log "Activating connection ens4-static";
#         assert_script_run "nmcli con up ens4-static";
#         step_log "Setting nameserver $dns_ip in /etc/resolv.conf";
#         assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";
#     };
#     barrier_wait "net_ready";
 
#     step 'P2. Ping client' => sub {
#         step_log "Checking connectivity to the client $client_ip (4 ICMP echo requests)";
#         assert_script_run "ping -c 4 $client_ip";
#     };
 
#     step 'P3. Create test user' => sub {
#         step_log "Creating user $test_user with shell /bin/bash";
#         assert_script_run "useradd -m -s /bin/bash $test_user";
#         step_log "Setting the password for $test_user";
#         assert_script_run "echo '$test_user:$test_pass' | chpasswd";
#         step_log "Opening permissions on /dev/ttyS0 (chmod 777)";
#         assert_script_run "chmod 777 /dev/ttyS0";
#     };
#     barrier_wait "user_ready";

#         # --- Step 1: Install the package ---
#     step 'S01. Install the package' => sub {
#         step_log "Installing the openssh package with dnf";
#         assert_script_run "dnf install -y openssh";
#     };
 
#     # --- Step 2: sshd configuration ---
#     step 'S02. sshd configuration' => sub {
#         step_log "Checking that the effective sshd configuration uses port 22";
#         assert_script_run "sshd -T | grep 'port 23'";
#     };
 
#     # --- Step 3: Start the service ---
#     step 'S03. Start the service' => sub {
#         step_log "Starting the sshd service";
#         assert_script_run "systemctl start sshd";
#         step_log "Checking that the sshd service is active";
#         assert_script_run "systemctl is-active sshd";
#     };
 
#     # --- Step 4: Autoload ---
#     step 'S04. Autoload' => sub {
#         step_log "Enabling the sshd service at boot and starting it now";
#         assert_script_run "systemctl enable --now sshd";
#         step_log "Checking that the sshd service is enabled";
#         assert_script_run "systemctl is-enabled sshd";
#     };
 
#     # --- Step 5: Listening port ---
#     step 'S05. Listening port' => sub {
#         step_log "Checking that something listens on TCP port 22";
#         assert_script_run "ss -lntp | grep ':22'";
#     };
 
#     # --- Step 6: firewalld ---
#     step 'S06. firewalld' => sub {
#         step_log "Checking that firewalld allows the ssh service";
#         assert_script_run "firewall-cmd --list-services | grep 'ssh'";
#     };
#     barrier_wait "package_ready";
 
#     # wait for the client to install the public key (steps 11-13)
#     barrier_wait "client_key_installed";
 
#     # We wait until the client checks the login using the correct/incorrect key (steps 14-15)
#     barrier_wait "client_key_checks_done";
 
#     # --- Step 16: Restart the sshd service ---
#     step 'S16. Restart the sshd service' => sub {
#         step_log "Restarting the sshd service";
#         assert_script_run "systemctl restart sshd";
#         step_log "Checking that the sshd service is active after the restart";
#         assert_script_run "systemctl is-active sshd";
#     };
#     barrier_wait "server_sshd_restarted";
 
#     # --- Step 18: Server reboot ---
#     step 'S18. Server reboot' => sub {
#         step_log "Rebooting the server and waiting for the console login";
#         reboot();
#     };
 
#     # --- Step 19: Service is active after reboot ---
#     step 'S19. Service is active after reboot' => sub {
#         step_log "Checking that the sshd service is active after the reboot";
#         assert_script_run "systemctl is-active sshd";
#     };
#     barrier_wait "server_rebooted";
 
#     # waiting for the client to complete the SSH check after the system reboot (step 20))
#     barrier_wait "client_post_reboot_done";
 
#     # --- Step 21: checking/installing the package update ---
#     step 'S21. Check and install the package update' => sub {
#         step_log "Checking for an openssh update (dnf check-update)";
#         my $rc = script_run("dnf check-update openssh", timeout => 300) // -1;
#         step_log "dnf check-update finished with exit code $rc (0 = up to date, 100 = update available, -1 = timeout)";
#         if ($rc == 100) {
#             # 100 = есть доступные обновления
#             step_log "An update is available, installing it with dnf update";
#             assert_script_run "dnf update -y openssh", timeout => 300;
#         }
#         elsif ($rc != 0) {
#             die "dnf check-update failed with code $rc";
#         }
#     };
 
#     # --- Step 22: Service active after update ---
#     step 'S22. Service is active after update' => sub {
#         step_log "Checking that the sshd service is active after the update";
#         assert_script_run "systemctl is-active sshd";
#     };
#     barrier_wait "server_updated";
 
#     # waiting for the client to complete the SSH check after the openssh update (step 23))
#     barrier_wait "client_final_checks_done";
 
#     # --- Step 27: Checking logs for errors ---
#     step 'S27. Check logs for errors' => sub {
#         step_log "Reading the last 100 lines of the sshd journal";
#         my $logs = script_output "journalctl -u sshd --no-pager -n 100";
#         step_log "Checking the journal for 'Failed', 'fatal' or 'error' entries";
#         die "sshd logs contain errors:\n$logs"
#           if $logs =~ /Failed|fatal|error/i;
#     };
 
#     # --- Step 28: General status of the OS ---
#     step 'S28. General status of the OS' => sub {
#         step_log "Verifying the openssh package files (rpm -V)";
#         assert_script_run "rpm -V openssh";
#         step_log "Checking the package database consistency (dnf check)";
#         assert_script_run "dnf check";
#         step_log "Checking that SELinux is in Enforcing mode";
#         assert_script_run "getenforce | grep 'Enforcing'";
#         step_log "Checking that port 22 is still listening";
#         assert_script_run "ss -lntp | grep ':22'";
#         step_log "Printing the kernel command line";
#         assert_script_run "cat /proc/cmdline";
#         step_log "Checking that there are no failed systemd units";
#         assert_script_run "systemctl --failed | grep '0 loaded units listed'";
#     };
    
# }
 
# # Отчёт пишется и при успехе, и при падении.
# sub post_fail_hook { write_step_report('ssh_server', failed => 1) }
# sub post_run_hook  { write_step_report('ssh_server') }
 
# 1;

# sub run {
#     barrier_create "net_ready", 2;
#     barrier_create "user_ready", 2;
#     barrier_create "package_ready", 2;
#     barrier_create "client_key_installed", 2;
#     barrier_create "client_key_checks_done", 2;
#     barrier_create "server_sshd_restarted", 2;
#     barrier_create "server_rebooted", 2;
#     barrier_create "client_post_reboot_done", 2;
#     barrier_create "server_updated", 2;
#     barrier_create "client_final_checks_done", 2;

#     # --- Preconditions ---
#     record_info "PRECONDITION";
#     assert_script_run "nmcli con add type ethernet ifname ens4 con-name ens4-static "
#         . "ipv4.addresses $server_ip/15 ipv4.gateway 172.16.2.2 "
#         . "ipv4.dns $dns_ip ipv4.method manual";
#     assert_script_run "nmcli con up ens4-static";
#     assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";
#     barrier_wait "net_ready";

#     assert_script_run "ping -c 4 $client_ip";
    
#     assert_script_run "useradd -m -s /bin/bash $test_user";
#     assert_script_run "echo '$test_user:$test_pass' | chpasswd";
#     assert_script_run "chmod 777 /dev/ttyS0";
#     barrier_wait "user_ready";

#     # # --- Step 1: Install the package ---
#     # assert_script_run "dnf install -y openssh";

#     # --- Step 2: sshd configuration ---
#     assert_script_run "sshd -T | grep 'port 22'";

#     # --- Step 3: Start the service ---
#     assert_script_run "systemctl start sshd";
#     assert_script_run "systemctl is-active sshd";

#     # --- Step 4: Autoload ---
#     assert_script_run "systemctl enable --now sshd";
#     assert_script_run "systemctl is-enabled sshd";

#     # --- Step 5: Listening port ---
#     assert_script_run "ss -lntp | grep ':22'";

#     # --- Step 6: firewalld ---
#     assert_script_run "firewall-cmd --list-services | grep 'ssh'";
#     barrier_wait "package_ready";

#     # wait for the client to install the public key (steps 11-13)
#     barrier_wait "client_key_installed";

#     # We wait until the client checks the login using the correct/incorrect key (steps 14-15)
#     barrier_wait "client_key_checks_done";

#     # --- Step 16: Restart the sshd service ---
#     assert_script_run "systemctl restart sshd";
#     assert_script_run "systemctl is-active sshd";
#     barrier_wait "server_sshd_restarted";

#     # --- Step 18: Server reboot ---
#     # enter_cmd "reboot";
#     # wait_still_screen(15);
#     # assert_screen 'console-root', 720;
#     # type_string 'root';
#     # send_key 'ret';
#     # wait_still_screen(3);
#     # type_string $root_password;
#     # send_key 'ret';
#     # assert_screen 'console-root-access', 720;
#     reboot();

#     # --- Step 19: Service is active after reboot ---
#     assert_script_run "systemctl is-active sshd";
#     barrier_wait "server_rebooted";

#     # waiting for the client to complete the SSH check after the system reboot (step 20))
#     barrier_wait "client_post_reboot_done";

#     # --- Step 21: checking/installing the package update ---
#     my $rc = script_run "dnf check-update openssh";
#     if ($rc == 100) {
#         # 100 = есть доступные обновления
#         assert_script_run "dnf update -y openssh", timeout => 300;
#     }
#     elsif ($rc != 0) {
#         die "dnf check-update failed with code $rc";
#     }

#     # --- Step 22: Service active after update ---
#     assert_script_run "systemctl is-active sshd";
#     barrier_wait "server_updated";

#     # waiting for the client to complete the SSH check after the openssh update (step 23))
#     barrier_wait "client_final_checks_done";

#     # --- Step 27: Checking logs for errors ---
#     my $logs = script_output "journalctl -u sshd --no-pager -n 100";
#     die "sshd logs contain errors:\n$logs"
#       if $logs =~ /Failed|fatal|error/i;

#     # --- Step 28: General status of the OS ---
#     assert_script_run "rpm -V openssh";
#     assert_script_run "dnf check";
#     assert_script_run "getenforce | grep 'Enforcing'";
#     assert_script_run "ss -lntp | grep ':22'";
#     assert_script_run "cat /proc/cmdline";
#     assert_script_run "systemctl --failed | grep '0 loaded units listed'";
# }

# sub test_flags {
#     return {fatal => 1, milestone => 0};
# }

# 1;