import subprocess
import sys
import setup_util
from os.path import expanduser

home = expanduser("~")

def start(args, logfile):
  setup_util.replace_text("php-phalcon-micro/public/index.php", "localhost", ""+ args.database_host +"")
  setup_util.replace_text("php-phalcon-micro/deploy/nginx.conf", "root .*\/FrameworkBenchmarks", "root " + home + "/FrameworkBenchmarks")

  try:
    subprocess.check_call("sudo chown -R www-data:www-data php-phalcon-micro", shell=True, stderr=logfile, stdout=logfile)
    subprocess.check_call("sudo php-fpm --fpm-config config/php-fpm.conf -g " + home + "/FrameworkBenchmarks/php-phalcon-micro/deploy/php-fpm.pid", shell=True, stderr=logfile, stdout=logfile)
    subprocess.check_call("sudo /usr/local/nginx/sbin/nginx -c " + home + "/FrameworkBenchmarks/php-phalcon-micro/deploy/nginx.conf", shell=True, stderr=logfile, stdout=logfile)
    return 0
  except subprocess.CalledProcessError:
    return 1
def stop(logfile):
  try:
    subprocess.call("sudo /usr/local/nginx/sbin/nginx -s stop", shell=True, stderr=logfile, stdout=logfile)
    subprocess.call("sudo kill -QUIT $( cat php-phalcon-micro/deploy/php-fpm.pid )", shell=True, stderr=logfile, stdout=logfile)
    subprocess.check_call("sudo chown -R $USER:$USER php-phalcon-micro", shell=True, stderr=logfile, stdout=logfile)
    return 0
  except subprocess.CalledProcessError:
    return 1
