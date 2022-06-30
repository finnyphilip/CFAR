# ABSTRACT
SONAR detection is one of the most important process which is carried out by comparing
the received signal amplitude to a threshold value. Since there are so many disadvantages
with fixed threshold, here adaptive threshold is used, known as Constant False Alarm
Rate(CFAR).

A hardware architecture that implements a CA-CFAR and OS-CFAR
processor is presented here. The detection schemes presented has the following advantage:
The technique yields unbiased estimates under a non-homogeneous underwater
environment, because the false alarm rate is maintained at a constant level while the
threshold changes with different underwater environments, in presence of interfering
targets. Functional verification is done using Matlab, Simulation in Xilinx Vivado and the
architecture is implemented in FPGA.
## CA-CFAR
- Take the average of the samples contained in the reference cells.
- Threshold is calculated based on the interference power contained in
the reference cells.
## OS-CFAR
- General idea of OS is that the noise estimation is based on the k-th
values of reference values sorted in ascending order.
- The arithmetic mean used in CA-CFAR algorithms is replaced by a
single rank of the ordered-statistic Xk.
- OS-CFAR uses only a single value to determine the threshold value,
the choice of N is less important compared to the CA-CFAR
