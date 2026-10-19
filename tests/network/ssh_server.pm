# openQA test
#
# Summary: OpenSSH (Server) — configuration and security checks, service
# restart, system reboot, log analysis, general OS status.
# Qase case: "OpenSSH Server - Проверка конфигурации и параметров безопасности"
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

    # Synchronisation points shared with ssh_client.pm (names must match on both sides)
    barrier_create($_, 2) for qw(
      net_ready
      user_ready
      server_ready
      failed_logins_done
      faillock_checked
      client_checks_done
      perms_broken
      client_perm_checked
      perms_restored
      server_sshd_restarted
      client_restart_checked
      server_rebooted
      client_reboot_checked
    );

    # --- Preconditions ---
    step 'Precondition. Network setup' => sub {
        run_cmd "Adding static connection ens4-static ($server_ip/15, gateway 172.16.2.2, DNS $dns_ip)" =>
          'nmcli con add type ethernet ifname ens4 con-name ens4-static '
          . "ipv4.addresses $server_ip/15 ipv4.gateway 172.16.2.2 "
          . "ipv4.dns $dns_ip ipv4.method manual";
        run_cmd 'Activating connection ens4-static' => 'nmcli con up ens4-static';
        run_cmd "Setting nameserver $dns_ip in /etc/resolv.conf" => "echo 'nameserver $dns_ip' > /etc/resolv.conf";
    };

    barrier_wait 'net_ready';

    step 'Precondition. Ping client' => sub {
        run_cmd "Checking connectivity to the client $client_ip (4 ICMP echo requests)" => "ping -c 4 $client_ip";
    };

    step 'Precondition. Create test user' => sub {
        run_cmd "Creating user $test_user with shell /bin/bash" => "useradd -m -s /bin/bash $test_user";
        run_cmd "Setting the password for $test_user" => "echo '$test_user:$test_pass' | chpasswd";
        run_cmd 'Opening permissions on /dev/ttyS0 (chmod 777)' => 'chmod 777 /dev/ttyS0';
    };

    barrier_wait 'user_ready';

    # --- Step 1: sshd configuration validity ---
    step 'Step 1. sshd configuration validity' => sub {
        run_cmd 'Validating the sshd configuration (sshd -t)' => 'sshd -t';
        run_cmd 'Printing the effective security-related sshd settings' =>
          'sshd -T | grep -E '
          . q{'^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|usepam|authorizedkeysfile|allowusers|denyusers) '};
        run_cmd 'Checking that the effective configuration uses port 22' => q{sshd -T | grep -x 'port 22'};
    };

    # --- Step 2: algorithms (crypto strength) ---
    step 'Step 2. Cryptographic algorithms' => sub {
        my $algs = q{sshd -T | grep -E '^(ciphers|macs|kexalgorithms|hostkeyalgorithms|pubkeyacceptedalgorithms) '};
        run_cmd 'Printing the effective ciphers, MACs, KEX, host key and pubkey algorithms' => $algs;
        run_cmd 'Checking that no legacy algorithms are enabled' =>
          "! $algs | grep -Ei '3des-cbc|aes128-cbc|hmac-md5|diffie-hellman-group1-sha1|(^|[ ,])ssh-rsa(,|\$)'";
        run_cmd 'Checking that modern ciphers and key exchange are present' =>
          q{sshd -T | grep -E '^ciphers ' | grep -E 'chacha20-poly1305|aes(128|256)-gcm'}
          . q{ && sshd -T | grep -E '^kexalgorithms ' | grep curve25519};
    };

    # --- Step 3: PAM integration ---
    step 'Step 3. PAM integration' => sub {
        run_cmd 'Checking that usepam is enabled' => q{sshd -T | grep -x 'usepam yes'};
        run_cmd 'Checking that /etc/pam.d/sshd exists' => 'ls -l /etc/pam.d/sshd';
    };

    # --- Step 4: Start the service and enable autostart ---
    step 'Step 4. Start sshd and enable autostart' => sub {
        run_cmd 'Enabling the sshd service at boot and starting it now' => 'systemctl enable --now sshd';
        run_cmd 'Checking that sshd is active and enabled' => 'systemctl is-active sshd && systemctl is-enabled sshd';
    };

    # --- Step 5: Listening port ---
    step 'Step 5. sshd listens on port 22' => sub {
        run_cmd 'Checking that port 22 is in LISTEN state and owned by sshd' =>
          q{ss -lntp | grep -E 'sshd|:22[[:space:]]'};
    };

    # --- Step 6: firewalld ---
    step 'Step 6. firewalld allows ssh' => sub {
        run_cmd 'Checking that firewalld is active' => 'systemctl is-active firewalld';
        run_cmd 'Checking that the ssh service is allowed in the public zone' =>
          q{firewall-cmd --zone=public --list-services | grep -w 'ssh'};
        run_cmd 'Reloading firewalld and checking that the ssh rule persists' =>
          'firewall-cmd --reload && firewall-cmd --query-service=ssh';
    };

    # sshd is up and reachable: the client may start its checks
    barrier_wait 'server_ready';

    # --- Step 7: Host key ownership and permissions ---
    step 'Step 7. Private host key owner and permissions' => sub {
        run_cmd 'Checking that the ed25519 host key is 640 root:ssh_keys' =>
          q{stat -c '%a %U:%G' /etc/ssh/ssh_host_ed25519_key | grep -x '640 root:ssh_keys'};
    };

    # --- Step 8: SELinux mode ---
    step 'Step 8. SELinux is in Enforcing mode' => sub {
        run_cmd 'Checking that SELinux is in Enforcing mode' => q{getenforce | grep 'Enforcing'};
    };

    # --- Step 9: SELinux file labels ---
    step 'Step 9. SELinux file labels' => sub {
        run_cmd 'Printing SELinux contexts of sshd and sshd_config' => 'ls -Z /usr/sbin/sshd /etc/ssh/sshd_config';
        run_cmd 'Checking that /usr/sbin/sshd has the sshd_exec_t type' => q{ls -Z /usr/sbin/sshd | grep 'sshd_exec_t'};
        run_cmd 'Checking that /etc/ssh/sshd_config has the etc_t type' => q{ls -Z /etc/ssh/sshd_config | grep 'etc_t'};
        run_cmd 'Checking that /etc/ssh needs no relabeling' => q{! restorecon -nR /etc/ssh 2>&1 | grep -i 'would relabel'};
    };

    # --- Step 10: No AVC denials since boot ---
    step 'Step 10. No SELinux AVC denials' => sub {
        run_cmd 'Checking for the absence of AVC denials since boot' =>
          q{! ausearch -m AVC,USER_AVC -ts boot | grep -q denied};
    };

    # The client has made 3 attempts with a wrong password
    barrier_wait 'failed_logins_done';

    # --- Step 11: pam_faillock ---
    step 'Step 11. PAM faillock state' => sub {
        run_cmd "Printing the faillock records of $test_user" => "faillock --user $test_user";
        # Do not let a possible lockout break the password login in the client's next steps
        run_cmd "Resetting the faillock counter of $test_user" => "faillock --user $test_user --reset", quiet => 1;
    };

    barrier_wait 'faillock_checked';
    barrier_wait 'client_checks_done';

    # --- Step 12: StrictModes ---
    step 'Step 12. StrictModes: insecure permissions on ~/.ssh' => sub {
        run_cmd "Making /home/$test_user/.ssh world-writable (chmod 777)" => "chmod 777 /home/$test_user/.ssh";
        barrier_wait 'perms_broken';

        step_log 'Waiting for the client to try the key login (it must be refused)';
        barrier_wait 'client_perm_checked';

        # Permissions must be restored even if the journal check fails, otherwise the client hangs
        my $ok = eval {
            run_cmd 'Looking for "bad ownership or modes" in the sshd journal' =>
              "journalctl -u sshd --no-pager --since '-5min' | grep 'bad ownership or modes'";
            1;
        };
        my $err = $@;
        run_cmd "Restoring permissions on /home/$test_user/.ssh (chmod 700)" => "chmod 700 /home/$test_user/.ssh";
        barrier_wait 'perms_restored';
        die $err unless $ok;
    };

    # --- Step 13: Restart the sshd service ---
    step 'Step 13. Restart sshd' => sub {
        run_cmd 'Restarting the sshd service' => 'systemctl restart sshd';
        run_cmd 'Checking that sshd is active after the restart' => 'systemctl is-active sshd';
    };

    barrier_wait 'server_sshd_restarted';
    barrier_wait 'client_restart_checked';

    # --- Step 14: Reboot ---
    step 'Step 14. Reboot and verify sshd' => sub {
        step_log 'Rebooting the server and waiting for the console login';
        reboot();
        run_cmd 'Checking that sshd is active after the reboot' => 'systemctl is-active sshd';
    };

    barrier_wait 'server_rebooted';
    barrier_wait 'client_reboot_checked';

    # --- Step 15: Log analysis (current boot; intentional denials are ignored) ---
    step 'Step 15. Analyze sshd/PAM logs' => sub {
        run_cmd 'Looking for error/failed/fatal entries in the sshd journal of the current boot' =>
          q{! journalctl -u sshd --no-pager -b | grep -iE 'error|failed|fatal'}
          . q{ | grep -v 'bad ownership or modes' | grep -v 'Failed publickey'};
    };

    # --- Step 16: Package integrity ---
    step 'Step 16. Verify the integrity of the installed package' => sub {
        run_cmd 'Verifying the openssh package files (rpm -V)' => 'rpm -V openssh', quiet => 1;
    };

    # --- Step 17: Failed systemd units ---
    step 'Step 17. No failed systemd units' => sub {
        run_cmd 'Checking that there are no failed systemd units' => q{systemctl --failed | grep '0 loaded units listed'};
    };
}

sub post_fail_hook { write_step_report('openssh-server', failed => 1) }
sub post_run_hook { write_step_report('openssh-server') }

1;
