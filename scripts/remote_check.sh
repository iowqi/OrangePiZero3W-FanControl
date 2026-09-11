#!/bin/bash
# 一次性登录香橙派 zero3w,勘查 PWM / 温度 / 系统环境
SSHPASS='0220' sshpass -e ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
  orangepi@10.206.118.176 '
echo "== uname =="; uname -a
echo "== pwm class =="; ls -l /sys/class/pwm/ 2>&1
echo "== pwmchip =="; for c in /sys/class/pwm/pwmchip*; do echo "-- $c npwm=$(cat $c/npwm 2>/dev/null)"; ls "$c" 2>/dev/null; done
echo "== pwm sysfs values =="; for p in /sys/class/pwm/pwmchip*/pwm*; do echo "-- $p: period=$(cat $p/period 2>/dev/null) duty=$(cat $p/duty_cycle 2>/dev/null) enable=$(cat $p/enable 2>/dev/null) polarity=$(cat $p/polarity 2>/dev/null)"; done
echo "== thermal =="; for z in /sys/class/thermal/thermal_zone*; do echo "-- $z type=$(cat $z/type 2>/dev/null) temp=$(cat $z/temp 2>/dev/null)"; done
echo "== os =="; head -2 /etc/os-release
echo "== fan/pwm services =="; systemctl list-units --type=service --no-pager 2>/dev/null | grep -iE "fan|pwm"; true
echo "== crontab =="; crontab -l 2>&1 | head -20
echo "== boot files =="; ls /boot/ 2>/dev/null | head -40
echo "== boot env =="; cat /boot/orangepiEnv.txt 2>/dev/null; cat /boot/armbianEnv.txt 2>/dev/null
echo "== dmesg pwm/fan =="; dmesg 2>/dev/null | grep -iE "pwm|fan" | tail -30
echo "== python =="; python3 --version
echo "== user groups =="; id
echo "== DONE =="
'
