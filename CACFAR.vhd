----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 15.12.2021
-- Design Name: 
-- Module Name: CACFAR - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.std_logic_textio.all;

use std.textio.all;

entity CACFAR is
	generic(
		DATA_WINDOW : natural := 64;
		DATA_W : natural := 16
	);
	port(
		clk    : in  std_logic;
		rst    : in  std_logic;
		we     : in  std_logic;
		i_data : in  std_logic_vector(DATA_W - 1 downto 0);
		o_data : out std_logic_vector(DATA_W - 1 downto 0)
	);
end CACFAR;

architecture Behavioral of CACFAR is

	-- FSM signals
	type states is (idle, read_cut, cfar_acc, fast_cfar_acc, cfar_ave, cfar_threshold, cfar_decision);
	signal state : states;

	-- RAM signals
	constant ADDR_WIDTH : positive := positive(ceil(log2(real(DATA_WINDOW))));
	type ram is array (0 to 2**ADDR_WIDTH - 1) of std_logic_vector(DATA_W - 1 downto 0);
	signal cells        : ram      := (others => (others => '0'));
	signal w_addr       : integer range 0 to 2**ADDR_WIDTH - 1; -- write address
	signal left_data    : std_logic_vector(DATA_W - 1 downto 0); -- read data port 1
	signal left_addr    : integer range 0 to 2**ADDR_WIDTH - 1; -- read address port 1 
	signal rigth_data   : std_logic_vector(DATA_W - 1 downto 0); -- read data port 2
	signal rigth_addr   : integer range 0 to 2**ADDR_WIDTH - 1; -- read address port 2
	signal ram_filled   : boolean;

	function get_divisor(value : natural)
		return signed is
		constant TOTAL_WIDTH : natural := 10;
		constant FRACT_WIDTH : natural := 9;
	begin
		return to_signed(integer(1.0/real(value) * real(2 ** FRACT_WIDTH)), TOTAL_WIDTH);
	end function get_divisor;
	

	-- Internal signals
	constant ACC_GROWTH  : natural := natural(ceil(log2(real(8))));
	constant ALPHA_WIDTH : natural := natural(ceil(log2(real(5)))) + 1;
	signal read_cut_ctr  : integer range 0 to 1; -- Pointer within each window
	signal window_ptr    : integer range 3 to 10; -- Pointer within each window
	signal cut_addr      : integer range 0 to 2**ADDR_WIDTH - 1; -- Pointer to the current cell under test    
	signal cut_value     : signed(DATA_W - 1 downto 0); -- Latch the value of the current cell under test
	signal left_acc      : signed(DATA_W + ACC_GROWTH downto 0); -- Accumulator of the left window
	signal rigth_acc     : signed(DATA_W + ACC_GROWTH downto 0); -- Accumulator of the rigth window
	signal total_acc     : signed(DATA_W + ACC_GROWTH downto 0); -- Sum of window accumulators
	signal ave           : signed(DATA_W + ACC_GROWTH + 10 downto 0);
	signal threshold     : signed(DATA_W + ACC_GROWTH + 10 + ALPHA_WIDTH downto 0);
	signal fast_ave_en   : boolean;

begin

	-- ram process
	ram_m : process(clk)
	begin
		if rising_edge(clk) then
			-- write port
			if we = '1' then
				cells(w_addr) <= i_data;
			end if;

			-- read ports
			left_data  <= cells(left_addr); -- Read port 1
			rigth_data <= cells(rigth_addr); -- Read port 2
		end if;
	end process;

	-- finite state machine process
	fsm_p : process(clk)
	begin
		if rising_edge(clk) then
			if rst = '0' then
				ram_filled   <= false;
				w_addr       <= 0;
				cut_addr     <= 0;
				window_ptr   <= 3;
				left_addr    <= 0;
				rigth_addr   <= 0;
				read_cut_ctr <= 0;
				cut_value    <= (others => '0');
				left_acc     <= (others => '0');
				rigth_acc    <= (others => '0');
				total_acc    <= (others => '0');
				ave          <= (others => '0');
				threshold    <= (others => '0');
				o_data       <= (others => '0');
				fast_ave_en  <= false;
			else
				case state is
					when idle =>
						if we = '1' then
							-- Update write address port
							if w_addr = ram'HIGH then
								w_addr <= ram'LOW;
							else
								w_addr <= w_addr + 1;
							end if;

							-- Update cut address
							if w_addr >= 0 and w_addr < 6 then -- Corner cases
								cut_addr  <= ram'HIGH + w_addr - 6;
								left_addr <= ram'HIGH + w_addr - 6;
							elsif w_addr = 6 then -- Wrap address
								cut_addr  <= ram'LOW;
								left_addr <= ram'LOW;
							else
								cut_addr  <= w_addr - 6;
								left_addr <= w_addr - 6;
							end if;

							-- State of the ram
							if w_addr = ram'HIGH then
								ram_filled <= true;
							end if;

							-- Move to next state
							if w_addr >= 12 or ram_filled then
								state <= read_cut;
							end if;
						end if;

					when read_cut =>
						if read_cut_ctr = 0 then -- wait for the cycle that ram needs.
							read_cut_ctr <= read_cut_ctr + 1;
						elsif read_cut_ctr = 1 then -- Read cut value and move to next state
							read_cut_ctr <= 0;
							cut_value    <= signed(left_data);
							if fast_ave_en then
								state <= fast_cfar_acc;
							else
								state <= cfar_acc;
							end if;
						end if;

					when cfar_acc =>    -- Update window pointer and accumulate data
						if window_ptr = 3 then -- Skip guard cells region 
							window_ptr <= window_ptr + 1;
							left_acc   <= (others => '0');
							rigth_acc  <= (others => '0');
						elsif window_ptr = 4 then -- Wait an extra cycle for data from ram
							window_ptr <= window_ptr + 1;
						elsif window_ptr < 9 then -- Window region
							window_ptr <= window_ptr + 1;
							left_acc   <= left_acc + signed(left_data);
							rigth_acc  <= rigth_acc + signed(rigth_data);
						elsif window_ptr = 9 then -- Sum of both window accumulation and next state
							state      <= cfar_ave;
							window_ptr <= 3;
							total_acc  <= left_acc + rigth_acc;
						end if;

						-- Update read address port A
						if cut_addr - window_ptr < ram'LOW then
							left_addr <= cut_addr + ram'HIGH - window_ptr + 1; -- Corner case
						else
							left_addr <= cut_addr - window_ptr;
						end if;

						-- Update read address port B
						if cut_addr + window_ptr > ram'HIGH then
							rigth_addr <= cut_addr - ram'HIGH + window_ptr - 1; -- Corner case
						else
							rigth_addr <= cut_addr + window_ptr;
						end if;
						fast_ave_en <= true;
					when fast_cfar_acc =>
						if window_ptr = 3 then
							window_ptr <= 7;
						else
							window_ptr <= window_ptr + 1;
						end if;
						if window_ptr = 8 then
							left_acc   <= left_acc + signed(left_data);
							rigth_acc  <= rigth_acc - signed(rigth_data);
						elsif window_ptr = 9 then
							left_acc   <= left_acc - signed(left_data);
							rigth_acc  <= rigth_acc + signed(rigth_data);
						elsif window_ptr = 10 then
							state      <= cfar_ave;
							window_ptr <= 3;
							total_acc  <= left_acc + rigth_acc;
						end if;
						
						-- Update read address port A
						if cut_addr - window_ptr < ram'LOW then
							left_addr <= cut_addr + ram'HIGH - window_ptr + 1; -- Corner case
						else
							left_addr <= cut_addr - window_ptr;
						end if;

						-- Update read address port B
						if cut_addr + (window_ptr - 1) > ram'HIGH then
							rigth_addr <= cut_addr - ram'HIGH + (window_ptr - 1) - 1; -- Corner case
						else
							rigth_addr <= cut_addr + window_ptr - 1;
						end if;

					when cfar_ave =>    -- Average
						ave   <= total_acc * get_divisor(8);
						-- Next state
						state <= cfar_threshold;

					when cfar_threshold => -- Threshold
						threshold <= to_signed(5, ALPHA_WIDTH) * ave;
						-- Next state
						state     <= cfar_decision;

					when cfar_decision => -- CUT cfar_decision                    
						if resize(cut_value, threshold'LENGTH) >= threshold then
							o_data <= std_logic_vector(cut_value);
						else
							o_data <= (others => '0');
						end if;

						-- Next state
						state <= idle;
				end case;
			end if;
		end if;
	end process;

end Behavioral;
