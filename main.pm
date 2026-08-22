use Mojo::Base -strict;
use testapi;
use autotest;
use File::Basename;

BEGIN { unshift @INC, dirname(__FILE__) . '/lib'; }

use scheduler 'load_yaml_schedule';

return 1 if load_yaml_schedule;

1;