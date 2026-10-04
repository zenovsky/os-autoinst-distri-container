use Mojo::Base 'basetest';
use testapi;
use StepReport;

my $distri = get_var('DISTRI');
my $version = get_var('VERSION');
my $build = get_var('BUILD');
my $arch = get_var('ARCH');

sub run {
    step "Poweroff system" => sub {
        step_log "Base qcow2 image $distri-$version-$build-$arch.qcow2 has been cteated";
        record_info "Create base image", "base qcow2 image $distri-$version-$build-$arch.qcow2 has been cteated";
    };

}

sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
sub post_run_hook  { write_step_report('ssh_client') }

1;