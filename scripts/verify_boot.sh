#!/bin/bash
# 重启后验证服务自启动
HOST=orangepi@10.206.118.176
SSHOPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

for i in 1 2 3 4 5 6; do
  if SSHPASS='0220' sshpass -e ssh $SSHOPTS $HOST 'echo OK' >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

SSHPASS='0220' sshpass -e ssh $SSHOPTS $HOST '
echo ==UPTIME==; uptime
echo ==STATUS==; systemctl --no-pager status pwm-fan.service | head -8
echo ==ENABLED==; systemctl is-enabled pwm-fan.service
echo ==JOURNAL-BOOT==; journalctl -b -u pwm-fan.service --no-pager
echo ==PWM==; cat /sys/class/pwm/pwmchip0/pwm0/period /sys/class/pwm/pwmchip0/pwm0/duty_cycle /sys/class/pwm/pwmchip0/pwm0/enable
echo ==TEMP==; cat /sys/class/thermal/thermal_zone0/temp
echo ==VERIFY-DONE==
'
