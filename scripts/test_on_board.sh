#!/bin/bash
# 在开发板上以 root 运行: 验证 PWM 输出与温控逻辑
# 注意: 本板极性 inversed, "占空比 p%" 实际写入 duty_cycle = period*(100-p)%
set -u
FAN=/home/orangepi/pwm-fan.py
PWM=/sys/class/pwm/pwmchip0/pwm0
T=/tmp/faketemp

echo "===== 1. --test 模式(占空比直设) ====="
python3 $FAN --test 0;   echo "  test 0%   -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 40000, 引脚低=停转)"
python3 $FAN --test 50;  echo "  test 50%  -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 20000)"
python3 $FAN --test 100; echo "  test 100% -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 0, 引脚高=全速)"

echo "===== 2. 温度逻辑(假温度文件) ====="
python3 $FAN --temp-file $T --interval 0.2 >/tmp/fan_test.log 2>&1 &
PID=$!

echo 55000 > $T; sleep 3
echo "  55°C -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 7000~9000, 即 80% 反相)"
echo 34000 > $T; sleep 6
echo "  34°C -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 40000, 停转)"
echo 36000 > $T; sleep 3
echo "  36°C -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 40000, 未达滞回启动阈值)"
echo 37000 > $T; sleep 5
echo "  37°C -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 ~30000, 最低 25% 反相)"
echo 62000 > $T; sleep 3
echo "  62°C -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 0, 100% 反相)"
echo 34000 > $T; sleep 6
echo "  34°C -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 40000, 再次停转)"

kill $PID 2>/dev/null; wait $PID 2>/dev/null
sleep 1
echo "  kill 后(安全占空比 100%) -> duty_cycle=$(cat $PWM/duty_cycle)  (期望 0)"
echo "===== 控制脚本日志 ====="
cat /tmp/fan_test.log
# 复位为停转状态, 交给后续验证/服务接管
echo 40000 > $PWM/duty_cycle
echo "===== 测试结束 ====="
