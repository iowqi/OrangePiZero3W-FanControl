#!/bin/bash
# 在开发板上以 root 运行: 服务闭环验证 —— 满载升温自动加速, 卸载自动降速
set -u
PWM=/sys/class/pwm/pwmchip0/pwm0
ZONE=/sys/class/thermal/thermal_zone0/temp

echo "== 服务状态 =="
systemctl --no-pager status pwm-fan.service | head -6
echo "== 静置 60 秒(让温度回到待机水平) =="
for i in $(seq 1 12); do
  echo "  t=$((i*5))s  temp=$(cat $ZONE)  duty_cycle=$(cat $PWM/duty_cycle)"
  sleep 5
done

echo "== 开始满载压测(4 核 busy loop), 观察 150 秒 =="
for i in 1 2 3 4; do yes > /dev/null & done
LOAD_PIDS=$(jobs -p)
for i in $(seq 1 30); do
  echo "  t=$((i*5))s  temp=$(cat $ZONE)  duty_cycle=$(cat $PWM/duty_cycle)"
  sleep 5
done
kill $LOAD_PIDS 2>/dev/null

echo "== 满载结束, 观察降温 90 秒 =="
for i in $(seq 1 18); do
  echo "  t=$((i*5))s  temp=$(cat $ZONE)  duty_cycle=$(cat $PWM/duty_cycle)"
  sleep 5
done

echo "== journal 尾部 25 行 =="
journalctl -u pwm-fan.service -n 25 --no-pager
echo "== 网络与自启动状态 =="
ip -4 addr show | grep -E "inet |^[0-9]" 
ls /etc/netplan/ 2>/dev/null
grep -rE "addresses|dhcp4" /etc/netplan/ 2>/dev/null | head -10
systemctl is-enabled pwm-fan.service
echo "== DEMO-DONE =="
