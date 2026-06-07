# 🧠 Systolic TPU Engine — SystemVerilog Implementation

A synthesizable, parameterized **Tensor Processing Unit (TPU)** core implemented in SystemVerilog. This project models the key architectural ideas behind Google's TPU: a weight-stationary systolic array performing **FP8 × BF16 → FP32** matrix multiplication, orchestrated by a finite-state-machine controller and surrounded by synchronous FIFOs for streaming data in/out.

---

## 📚 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [System Block Diagram](#system-block-diagram)
  - [Systolic Array Internals](#systolic-array-internals)
  - [Processing Element (PE)](#processing-element-pe)
  - [Floating-Point Datapath](#floating-point-datapath)
- [Module Descriptions](#module-descriptions)
- [Numeric Formats](#numeric-formats)
- [Controller FSM](#controller-fsm)
- [Data Flow Walkthrough](#data-flow-walkthrough)
- [File Structure](#file-structure)
- [References](#references)

---

## Overview

Modern AI workloads are dominated by matrix multiplications. Google designed the TPU to execute these with extreme efficiency using a **systolic array** — a grid of simple multiply-accumulate (MAC) processing elements where data flows rhythmically from neighbor to neighbor without any global memory reads inside the array.

> *"Systolic array is a hardware design architecture consisting of a grid of interconnected processing elements (PE). Each PE performs a small computation (e.g. multiply and accumulate) and passes the results to neighboring PEs."*
> — [TPU Deep Dive, Henry Ko](https://henryhmko.github.io/posts/tpu/tpu.html)

![Systolic Array Diagram](https://henryhmko.github.io/posts/tpu/images/systolic_arr.png)
*Systolic array data flow: weights stream top-to-bottom, activations stream left-to-right.*

This RTL project implements a fully synthesizable **N×N systolic array engine** (default N=8, scalable to N=256) with:

- **Mixed-precision arithmetic**: FP8 (E4M3) weights × BF16 activations → FP32 accumulation
- **Weight-stationary dataflow** with input skewing for wave-front propagation
- **6-state FSM controller** managing load → feed → wait → readout pipeline
- **Three synchronous FIFOs** for weight, activation, and result streaming
- **Scalar I/O ports** for clean synthesis with no unpacked array boundaries at the top level

---

## Architecture

### System Block Diagram

```
                  ┌─────────────────────────────────────────────────────┐
                  │                    tpu_top (N=8)                    │
                  │                                                      │
  weight_wr_data ─►  ┌──────────────┐    ┌──────────────────────────┐  │
  weight_wr_en  ─►   │ Weight FIFO  │    │   systolic_controller    │  │
                  │   │  8-bit       ├───►│                          │  │
                  │   │  Depth=N²    │    │   ST_IDLE                │  │
  data_wr_data  ─►   └──────────────┘    │   ST_LOAD_BUFFERS        │  │
  data_wr_en    ─►                       │   ST_FEED                │  │
                  │   ┌──────────────┐   │   ST_WAIT                │  │
                  │   │  Data FIFO   ├───►   ST_READOUT              │  │
                  │   │  16-bit      │    │   ST_DONE                │  │
                  │   │  Depth=N²    │    └────────────┬─────────────┘  │
                  │   └──────────────┘                 │ control        │
                  │                                    ▼                │
                  │   ┌──────────────┐   ┌──────────────────────────┐  │
  result_rd_data ◄─   │ Result FIFO  │◄──│    systolic_array        │  │
  result_rd_en  ─►   │  32-bit      │   │    N×N PE Grid           │  │
                  │   │  Depth=N²    │   │  (process_element)       │  │
                  │   └──────────────┘   └──────────────────────────┘  │
                  │                                                      │
                  └─────────────────────────────────────────────────────┘
```

### Systolic Array Internals

The systolic array is at the heart of the TPU, exactly as described in Google's original design:

![TPU Single Chip Diagram](https://henryhmko.github.io/posts/tpu/images/single_chip.png)
*Google TPUv4 single chip — the MXU at the center is the 128×128 systolic array.*

In this implementation the N×N PE grid works as follows:

- **Weights** enter from the **top** and propagate **downward**, one column at a time
- **Activations** enter from the **left** and propagate **rightward**, one row at a time
- Each PE accumulates `weight × activation` into a 32-bit FP accumulator
- **Input skewing registers** stagger each row/column by 1 cycle, creating the diagonal wave-front that drives correct matrix multiplication

```
        col 0    col 1    col 2
         │        │        │
row 0 ──► PE[0,0]─► PE[0,1]─► PE[0,2]──►
         │        │        │
row 1 ──► PE[1,0]─► PE[1,1]─► PE[1,2]──►
         │        │        │
row 2 ──► PE[2,0]─► PE[2,1]─► PE[2,2]──►
         ▼        ▼        ▼
```

Weights flow **↓** (top → bottom). Activations flow **→** (left → right). Each PE holds its own partial sum.

### Processing Element (PE)

Every `process_element` instance contains three sub-components:

```
        weight_in (FP8)
              │
              ▼
    ┌─────────────────┐
    │  fp8_bf16_mult  │◄── data_in (BF16)
    └────────┬────────┘
             │ product (FP32)
             ▼
    ┌─────────────────┐
    │   fp32_adder    │◄── acc_reg (FP32)
    └────────┬────────┘
             │
             ▼
         acc_reg (FP32)  ──► acc_out
             │
    weight_out ◄── weight_in  (forwarded to next row)
    data_out   ◄── data_in    (forwarded to next col)
```

The `clear_acc_in` signal resets the accumulator to just the current product (i.e., starts a new dot product), enabling back-to-back matrix operations without stalling.

### Floating-Point Datapath

The FP datapath spans three modules:

| Stage | Module | Operation |
|-------|--------|-----------|
| Multiply | `fp8_bf16_mult` | FP8 E4M3 × BF16 → FP32 product |
| Accumulate | `fp32_adder` | FP32 + FP32 → FP32 sum |
| Pack | (inside both) | IEEE-754 sign, exponent, fraction assembly |

---

## Module Descriptions

### `tpu_top.sv`
Top-level integration module. Instantiates all three FIFOs, the controller, and the systolic array. All external ports are **scalar** (no unpacked arrays), making this cleanly synthesizable.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | `8` | Array dimension (N×N PEs). Scalable up to 256. |

**Key I/O:**

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `start_i` | In | 1 | Begin computation handshake |
| `done_o` | Out | 1 | Computation complete handshake |
| `weight_fifo_wr_data` | In | 8 | FP8 weight to enqueue |
| `data_fifo_wr_data` | In | 16 | BF16 activation to enqueue |
| `result_fifo_rd_data` | Out | 32 | FP32 result to dequeue |

---

### `systolic_array.sv`
Generates the N×N PE grid using `generate`/`genvar` loops. Handles:

- **Internal weight and data buffers** (N×N arrays), populated element-by-element from the scalar FIFOs
- **Input skewing**: column `j` weight is delayed `j` cycles; row `i` activation is delayed `i` cycles
- **Serialized readout**: a 2D mux selects any PE's accumulator by `(result_row_sel, result_col_sel)`

---

### `process_element.sv`
A single MAC unit with registered forwarding paths. On each enabled clock:

- Multiplies `weight_in × data_in` via `fp8_bf16_mult`
- Adds the product to `acc_reg` via `fp32_adder` (or loads fresh if `clear_acc_in`)
- Registers and forwards `weight_in → weight_out` (to the PE below)
- Registers and forwards `data_in → data_out` (to the PE to the right)

---

### `fp8_bf16_mult.sv`
Combinational FP multiplier. Steps:

1. Decode FP8 E4M3 (1 sign + 4 exp + 3 frac, bias=7) and BF16 (1 sign + 8 exp + 7 frac, bias=127)
2. XOR signs for result sign
3. Add biased exponents, subtract only the FP8 bias (`eout = ea + eb − 7`)
4. Multiply 5-bit × 8-bit mantissas (hidden 1 prepended) → 13-bit product
5. Normalize (shift right by 1 and increment exponent if MSB set)
6. Pack into IEEE-754 FP32

---

### `fp32_adder.sv`
Combinational IEEE-754 FP32 adder (simplified). Steps:

1. Align smaller exponent's mantissa by right-shifting
2. Add or subtract mantissas based on signs
3. Normalize result (shift left until leading 1 restored, or right-shift on overflow)
4. Pack into FP32

> ⚠️ **Simplification note**: Both FP modules intentionally omit NaN, Infinity, denormal, rounding, overflow, and underflow handling to keep RTL concise for study purposes.

---

### `systolic_controller.sv`
6-state Moore FSM that sequences the entire computation. Controls FIFO read/write enables, buffer write selects, feed index, result readout selects, and systolic array enable.

---

### `sync_fifo.sv`
Parameterized synchronous FIFO with configurable `WIDTH` and `DEPTH`. Provides `full`, `empty`, and `count` status signals. Used for all three data channels (weight, activation, result).

---

## Numeric Formats

This design uses three floating-point formats across the datapath:

### FP8 — E4M3 (Weights)

```
  Bit:   7      6:3      2:0
       +-----+---------+-------+
       | Sign| Exponent| Frac  |   Bias = 7
       +-----+---------+-------+
         1b      4b       3b
```

FP8 was introduced to reduce weight storage and bandwidth in modern ML accelerators. Google uses FP8 in TPUv5 and beyond.

### BF16 — Brain Floating Point (Activations)

```
  Bit:  15      14:7     6:0
       +-----+----------+-------+
       | Sign| Exponent | Frac  |   Bias = 127
       +-----+----------+-------+
         1b      8b        7b
```

BF16 shares the same 8-bit exponent as FP32, making FP32↔BF16 conversion trivial (just truncate/pad the fraction). It was introduced in TPUv2 for training workloads.

![BF16 Format](https://qsysarch.com/images/tensor-processors/bf16.webp)
*BF16 vs FP32: same exponent range, reduced mantissa precision.*

### FP32 — IEEE-754 Single Precision (Accumulator)

```
  Bit:  31      30:23      22:0
       +------+-----------+-------------+
       | Sign | Exponent  |  Fraction   |   Bias = 127
       +------+-----------+-------------+
         1b       8b           23b
```

Accumulation in FP32 prevents precision loss when summing many FP8×BF16 products.

---

## Controller FSM

The `systolic_controller` drives the full computation lifecycle in 6 states:

```
                 ┌──────────────────────────────────────────────┐
                 │                                              │
                 ▼                                              │
           ┌──────────┐   start_i=1    ┌────────────────┐      │
           │ ST_IDLE  ├───────────────►│ ST_LOAD_BUFFERS│      │
           └──────────┘                └───────┬────────┘      │
                                               │ N² elements   │
                                               ▼ loaded        │
                                       ┌───────────────┐       │
                                       │   ST_FEED     │       │
                                       │  (N cycles)   │       │
                                       └───────┬───────┘       │
                                               │               │
                                               ▼               │
                                       ┌───────────────┐       │
                                       │   ST_WAIT     │       │
                                       │  (2N cycles)  │       │
                                       └───────┬───────┘       │
                                               │               │
                                               ▼               │
                                       ┌───────────────┐       │
                                       │  ST_READOUT   │       │
                                       │  (N² cycles)  │       │
                                       └───────┬───────┘       │
                                               │               │
                                               ▼               │
                                       ┌───────────────┐       │
                                       │   ST_DONE     ├───────┘
                                       │  (done_o=1)   │
                                       └───────────────┘
```

| State | Duration | Action |
|-------|----------|--------|
| `ST_IDLE` | Until `start_i` | Wait for start signal |
| `ST_LOAD_BUFFERS` | N² cycles | Pop weights+activations from FIFOs into internal buffers |
| `ST_FEED` | N cycles | Feed one vector per cycle with `clear_acc` on cycle 0 |
| `ST_WAIT` | 2N cycles | Let wave-fronts propagate through the full array |
| `ST_READOUT` | N² cycles | Serialize all N² accumulator outputs into result FIFO |
| `ST_DONE` | 1 cycle | Assert `done_o`, return to `ST_IDLE` |

**Total latency per N×N matrix multiply** ≈ `N² + N + 2N + N² + 1` = `2N² + 3N + 1` cycles.

---

## Data Flow Walkthrough

Here is how one complete N×N matrix multiply progresses through the system:

```
Step 1 — Pre-load (host writes to FIFOs):
  ┌─────────────────────────────────────┐
  │  Host pushes N² FP8 weights and     │
  │  N² BF16 activations into FIFOs     │
  │  via weight_fifo_wr_en /            │
  │  data_fifo_wr_en                    │
  └───────────────────┬─────────────────┘
                      │ start_i=1
                      ▼
Step 2 — ST_LOAD_BUFFERS:
  Controller pops FIFOs one element/cycle
  and writes to internal N×N weight_buffer
  and data_buffer using (wr_row_sel, wr_col_sel)

Step 3 — ST_FEED:
  For feed_idx = 0 to N-1:
    • weight_array[j] = weight_buffer[feed_idx][j]
    • data_array[i]   = data_buffer[i][feed_idx]
    → Skewing registers stagger inputs diagonally
    → Wave-fronts cascade through the PE grid

Step 4 — ST_WAIT:
  Array keeps running (sys_en=1) for 2N cycles
  to let the last wave-front reach PE[N-1,N-1]

Step 5 — ST_READOUT:
  Controller iterates (result_row_sel, result_col_sel)
  over all N² PEs and writes each acc_out to result FIFO

Step 6 — ST_DONE:
  done_o=1 for one cycle → host reads result FIFO
```

The pipelining philosophy here directly mirrors Google's TPU design:

![TPU Pipelined Pointwise Operation](https://henryhmko.github.io/posts/tpu/images/pipeline_pointwise.gif)
*Pipelined data movement on a TPU — data flows through the array in a wave pattern.*

---

## File Structure

```
.
├── tpu_top.sv              # Top-level integration (FIFOs + controller + array)
├── systolic_array.sv       # N×N PE grid with skewing and serialized readout
├── systolic_controller.sv  # 6-state FSM controller
├── process_element.sv      # Single MAC unit (multiplier + adder + registers)
├── fp8_bf16_mult.sv        # FP8 E4M3 × BF16 → FP32 combinational multiplier
├── fp32_adder.sv           # FP32 + FP32 → FP32 combinational adder
└── sync_fifo.sv            # Parameterized synchronous FIFO
```

### Module Hierarchy

```
tpu_top
├── sync_fifo  (u_weight_fifo)       8-bit,  depth=N²
├── sync_fifo  (u_data_fifo)        16-bit,  depth=N²
├── sync_fifo  (u_result_fifo)      32-bit,  depth=N²
├── systolic_controller (u_controller)
└── systolic_array (u_systolic_array)
    └── process_element [N×N] (u_pe)
        ├── fp8_bf16_mult (u_fp8_bf16_mult)
        └── fp32_adder    (u_adder)
```

---

## References

This project was designed with inspiration and conceptual grounding from the following resources:

1. **Henry Ko — TPU Deep Dive**  
   A comprehensive bottom-up walkthrough of TPU single-chip internals, systolic arrays, and multi-chip topology (racks, pods, torus interconnects).  
   🔗 https://henryhmko.github.io/posts/tpu/tpu.html

2. **Telesens — Systolic Architectures**  
   In-depth explanation of systolic array dataflow patterns and their application to matrix multiplication, convolution, and other regular computations.  
   🔗 https://www.telesens.co/2018/07/30/systolic-architectures/

3. **Google Cloud — TPU System Architecture (Official Docs)**  
   Official Google documentation covering TensorCores, MXUs, pods, slices, Multislice, SparseCores, and torus topologies across TPU generations.  
   🔗 https://docs.cloud.google.com/tpu/docs/system-architecture-tpu-vm

4. **QSysArch — TPU Architecture: High Level System Architecture**  
   A system-level view of TPU architecture evolution from TPUv1 through modern generations, covering BF16, HBM, ICI, and comparison with GPUs.  
   🔗 https://qsysarch.com/posts/tpu-architecture/

---

> **Disclaimer:** The FP arithmetic modules (`fp8_bf16_mult`, `fp32_adder`) are intentionally simplified for educational clarity. They do not handle NaN, Infinity, denormals, rounding modes, overflow, or underflow. Do not use in production without adding IEEE-754 compliant handling.
