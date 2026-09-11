#!/bin/bash
# 在开发板上以 root 运行: 用真实 CPU 满载的温度响应验证风扇方向
# 原理: 本板极性 inversed, 假设 duty_cycle=40000(引脚低) => 风扇停,
#       duty_cycle=0(引脚高) => 风扇全速。
# 阶段1: 满载 + "停转" -> 若温度快速攀升, 说明 duty=40000 确实停转;
# 阶段2: 满载 + "全速" -> 若温度回落, 说明 duty=0 确实全速, 映射正确。
set -u
PWM=/sys/class/pwm/pwmchip0/pwm0
ZONES=$(for z in /sys/class/thermal/thermal_zone*; do
          t=$(cat $z/type 2>/dev/null || true)
          case "$t" in *cpu*) echo "$z/temp";; esac
        done)

read_temp() {
  local max=0 v
  for f in $ZONES; do
    v=$(cat $f 2>/dev/null || echo 0)
    [ "$v" -gt "$max" ] && max=$v
  done
  echo $max
}

# 压满 CPU(4 核)
for i in 1 2 3 4; do yes > /dev/null & done
LOAD_PIDS=$(jobs -p)
sleep 1

echo "== 阶段1: duty_cycle=40000 (假设: 风扇停) + 满载, 观察 90 秒 =="
echo 40000 > $PWM/duty_cycle
for i in $(seq 1 18); do
  t=$(read_temp)
  echo "  t=$((i*5))s  CPU温度=$t m°C"
  if [ "$t" -ge 88000 ]; then echo "  !! 达到 88°C, 提前切换风扇全速"; break; fi
  sleep 5
done

echo "== 阶段2: duty_cycle=0 (假设: 风扇全速) + 满载, 观察 90 秒 =="
echo 0 > $PWM/duty_cycle
for i in $(seq 1 18); do
  t=$(read_temp)
  echo "  t=$((i*5))s  CPU温度=$t m°C"
  if [ "$t" -le 60000 ]; then echo "  !! 降到 60°C 以下, 提前结束"; break; fi
  sleep 5
done

kill $LOAD_PIDS 2>/dev/null
sleep 2
echo "== 满载结束后 30 秒 =="
for i in 1 2 3 4 5 6; do
  t=$(read_temp)
  echo "  t=$((i*5))s  CPU温度=$t m°C"
  sleep 5
done
echo 40000 > $PWM/duty_cycle   # 复位: 风扇停, 交给服务接管
echo "== 验证结束 =="
