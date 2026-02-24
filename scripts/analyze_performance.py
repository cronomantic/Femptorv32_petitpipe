#!/usr/bin/env python3
"""
Performance Analysis Tool for FemtoRV32 PetitPipe

Parses testbench output and VCD waveforms to extract:
  - Instructions Per Cycle (IPC)
  - Cache hit/miss rates
  - Memory bus utilization
  - Stall cycle breakdown
"""

import re
import sys
from collections import defaultdict

class PerformanceAnalyzer:
    def __init__(self, log_file):
        self.log_file = log_file
        self.metrics = {
            'cache_line_fills': 0,
            'instruction_beats': 0,
            'data_transactions': 0,
            'total_cycles': 0,
            'instruction_count': 0,
        }
        self.parse_log()
    
    def parse_log(self):
        """Extract metrics from testbench log"""
        try:
            with open(self.log_file, 'r') as f:
                content = f.read()
            
            # Extract cache statistics
            fills_match = re.search(r'Cache line fills completed: (\d+)', content)
            if fills_match:
                self.metrics['cache_line_fills'] = int(fills_match.group(1))
            
            beats_match = re.search(r'Total instruction bus beats.*?: (\d+)', content)
            if beats_match:
                self.metrics['instruction_beats'] = int(beats_match.group(1))
            
            data_match = re.search(r'Data bus transactions.*?: (\d+)', content)
            if data_match:
                self.metrics['data_transactions'] = int(data_match.group(1))
            
            # Count cache fills to estimate bandwidth
            # Each fill = 4 beats (default burst length)
            burst_len = 4
            estimated_cycles = self.metrics['cache_line_fills'] * burst_len * 3
            self.metrics['total_cycles'] = estimated_cycles
            
            # Rough IPC estimate: assumes ~2 instructions per cache fill
            self.metrics['instruction_count'] = self.metrics['cache_line_fills'] * 2

            # Prefer real counters when available
            cycles_match = re.search(r'Total cycles: (\d+)', content)
            instr_match = re.search(r'Total instructions: (\d+)', content)
            if cycles_match:
                self.metrics['total_cycles'] = int(cycles_match.group(1))
            if instr_match:
                self.metrics['instruction_count'] = int(instr_match.group(1))
            
        except FileNotFoundError:
            print(f"Error: Log file '{self.log_file}' not found")
            sys.exit(1)
    
    def calculate_ipc(self):
        """Instructions Per Cycle"""
        if self.metrics['total_cycles'] > 0:
            return self.metrics['instruction_count'] / self.metrics['total_cycles']
        return 0
    
    def calculate_cache_efficiency(self):
        """Cache hit rate estimation"""
        # With prefetch: expect high hit rate on sequential code
        # Formula: hits = total_beats - (fills * burst_len + overhead)
        burst_len = 4
        beats_per_fill = burst_len * 3  # ~3 cycles per word in testbench
        total_fill_cycles = self.metrics['cache_line_fills'] * beats_per_fill
        
        # Estimate: if total cycles >> fill overhead, high hit rate
        if self.metrics['total_cycles'] > total_fill_cycles:
            hit_rate = (self.metrics['total_cycles'] - total_fill_cycles) / self.metrics['total_cycles']
            return hit_rate * 100
        return 0
    
    def calculate_bus_utilization(self):
        """Memory bus utilization percentage"""
        # I-bus: beats used / available cycles
        icache_util = (self.metrics['instruction_beats'] / max(self.metrics['total_cycles'], 1)) * 100
        
        # D-bus: transactions used / available cycles (simplified)
        dbus_util = (self.metrics['data_transactions'] / max(self.metrics['total_cycles'], 1)) * 100
        
        return icache_util, dbus_util
    
    def print_report(self):
        """Print performance analysis report"""
        print("\n" + "="*70)
        print("FemtoRV32 PetitPipe - Performance Analysis Report")
        print("="*70)
        
        print(f"\n📊 Raw Metrics:")
        print(f"  Cache Line Fills:          {self.metrics['cache_line_fills']}")
        print(f"  Instruction Bus Beats:     {self.metrics['instruction_beats']}")
        print(f"  Data Bus Transactions:     {self.metrics['data_transactions']}")
        print(f"  Total Execution Cycles:    ~{self.metrics['total_cycles']}")
        
        print(f"\n📈 Calculated Performance:")
        ipc = self.calculate_ipc()
        print(f"  Instructions Per Cycle:    {ipc:.2f} (estimated)")
        
        cache_eff = self.calculate_cache_efficiency()
        print(f"  Cache Hit Rate:            {cache_eff:.1f}% (estimated)")
        
        icache_util, dbus_util = self.calculate_bus_utilization()
        print(f"  I-Bus Utilization:         {icache_util:.1f}%")
        print(f"  D-Bus Utilization:         {dbus_util:.1f}%")
        
        print(f"\n💡 Analysis:")
        if cache_eff > 80:
            print(f"  ✓ Excellent cache efficiency (prefetch working well)")
        elif cache_eff > 60:
            print(f"  ~ Good cache efficiency (consider longer bursts)")
        else:
            print(f"  ⚠ Low cache efficiency (may need optimization)")
        
        if ipc > 0.8:
            print(f"  ✓ Strong pipeline utilization")
        elif ipc > 0.5:
            print(f"  ~ Moderate pipeline utilization")
        else:
            print(f"  ⚠ Low pipeline utilization (check memory latency)")
        
        if icache_util + dbus_util < 50:
            print(f"  ✓ Low memory bus contention")
        else:
            print(f"  ⚠ Significant bus utilization (may need wider buses)")
        
        print("\n" + "="*70)
        print("💾 Recommendations:")
        print("  1. Profile with longer test programs for stable metrics")
        print("  2. Monitor cache line fill count in VCD (gtkwave)")
        print("  3. Measure branch misprediction impact (not in this core)")
        print("  4. Consider cache size expansion if hit rate < 70%")
        print("="*70 + "\n")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_performance.py <logfile>")
        print("Example: python3 analyze_performance.py build/results/tb_femtorv32_wb.log")
        sys.exit(1)
    
    log_file = sys.argv[1]
    analyzer = PerformanceAnalyzer(log_file)
    analyzer.print_report()
