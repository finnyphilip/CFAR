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


use std.textio.all;

entity CACFAR is
	generic(
        -- Data window size
		DATA_WINDOW : natural := 64;
        -- CACFAR window size width
		CFAR_WINDOW_W : natural := 4;
        -- data width
		DATA_W : natural := 16
	);
	port(
        -- clock
		clk    : in  std_logic;
        -- active-low reset
		rst    : in  std_logic;
		-- cacfar window size, valid range is [5; DATA_WINDOW]
		i_cfar_window : in std_logic_vector(CFAR_WINDOW_W - 1 downto 0);
		-- leading/lagging windows size 
		i_m : in std_logic_vector(CFAR_WINDOW_W - 1 downto 0);
		-- cacfar/leading/lagging window sizes write enable
		i_cfar_window_we : in std_logic;
        -- data write enable
		we     : in  std_logic;
        -- input data
		i_data : in  std_logic_vector(DATA_W - 1 downto 0);
        -- output data
		o_data : out std_logic_vector(DATA_W - 1 downto 0);
		o_tag  : out std_logic
	);
end CACFAR;

architecture Behavioral of CACFAR is

    -- Define the maximum M value for given DATA_WINDOW
	constant M_MAX : natural := (DATA_WINDOW - 1)/2 - 1;
    -- Define the maximum G value for given DATA_WINDOW
	constant G_MAX : natural := (DATA_WINDOW - 2*M_MAX - 1)/2;
    
    -- Define divisors coefficients parameters - total width, fractional part width and array of them
	constant DIVISORS_TOTAL_WIDTH : natural := 10;
	constant DIVISORS_FRACT_WIDTH : natural := 9;
	type arrayOfDivisors is array (natural range <>) of unsigned(DIVISORS_TOTAL_WIDTH - 1 downto 0); 
    
    -- Divisors array nitialization function
    -- Array stores 1/(2*m) values for each m in [1;M_MAX]
    function init_divisors return arrayOfDivisors is
		variable rom : arrayOfDivisors(1 to M_MAX) := (others => (others => '0'));
	begin
		for i in rom'range loop
			rom(i) := to_unsigned(integer(1.0/real(2*i) * real(2 ** DIVISORS_FRACT_WIDTH)), DIVISORS_TOTAL_WIDTH);
		end loop;
		return rom;
	end function init_divisors;
	
    -- Define and init array of divisors
	constant DIVISORS : arrayOfDivisors := init_divisors;
    
	-- FSM signals
	type states is (idle, read_cut, cfar_acc, fast_cfar_acc, cfar_ave, cfar_threshold, cfar_decision);
	signal state : states;

	-- RAM signals
	constant ADDR_WIDTH : positive := positive(ceil(log2(real(DATA_WINDOW ))));
	type ram is array (0 to 2**ADDR_WIDTH - 1) of std_logic_vector(DATA_W - 1 downto 0);
	signal cells        : ram      := (others => (others => '0'));
	signal w_addr       : integer range 0 to 2**ADDR_WIDTH - 1; -- write address
	signal left_data    : std_logic_vector(DATA_W - 1 downto 0); -- read data port 1
	signal left_addr    : integer range 0 to 2**ADDR_WIDTH - 1; -- read address port 1 
	signal rigth_data   : std_logic_vector(DATA_W - 1 downto 0); -- read data port 2
	signal rigth_addr   : integer range 0 to 2**ADDR_WIDTH - 1; -- read address port 2
	signal ram_filled   : boolean;

	
	-- Internal signals
	constant ACC_GROWTH  : natural := natural(ceil(log2(real(M_MAX))));
	constant ALPHA_WIDTH : natural := natural(ceil(log2(real(5)))) + 1;
	signal read_cut_ctr  : integer range 0 to 1; -- Pointer within each window
	signal window_ptr    : integer range 2 to M_MAX + G_MAX + 2; -- Pointer within each window
	signal cut_addr      : integer range 0 to 2**ADDR_WIDTH - 1; -- Pointer to the current cell under test    
	signal cut_value     : signed(DATA_W - 1 downto 0); -- Latch the value of the current cell under test
	signal left_acc      : signed(DATA_W + ACC_GROWTH downto 0); -- Accumulator of the left window
	signal rigth_acc     : signed(DATA_W + ACC_GROWTH downto 0); -- Accumulator of the rigth window
	signal total_acc     : signed(DATA_W + ACC_GROWTH downto 0); -- Sum of window accumulators
	signal ave           : signed(DATA_W + ACC_GROWTH + 10 downto 0);
	signal threshold     : signed(DATA_W + ACC_GROWTH + 10 + ALPHA_WIDTH downto 0);
	signal fast_ave_en   : boolean;
	signal cfar_window   : natural range 0 to DATA_WINDOW;
	signal m : natural range 1 to M_MAX;
	signal g : natural range 1 to G_MAX;

begin
	
	-- latch cfar window size
	process(clk)
	begin
		if rising_edge(clk) then
			if rst = '0' then
				cfar_window <= 12; -- some default value
				m <= 4; -- some default value
			elsif i_cfar_window_we = '1' then
				cfar_window <= to_integer(unsigned(i_cfar_window));
				m <= to_integer(unsigned(i_m));
			end if;
		end if;
	end process;
		
    -- finding g value
	g <= (cfar_window - 2*m - 1) / 2;
	
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
				window_ptr   <= 2;
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
				o_tag        <= '0';
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
							if w_addr >= 0 and w_addr < cfar_window/2 then -- Corner cases
								cut_addr  <= ram'HIGH + w_addr - cfar_window/2;
								left_addr <= ram'HIGH + w_addr - cfar_window/2;
								rigth_addr <= ram'HIGH + w_addr - (cfar_window/2 - 1);
							elsif w_addr = 6 then -- Wrap address
								cut_addr  <= ram'LOW;
								left_addr <= ram'LOW;
								rigth_addr <= ram'low + 1;
							else
								cut_addr  <= w_addr - cfar_window/2;
								left_addr <= w_addr - cfar_window/2;
								rigth_addr <= w_addr - (cfar_window/2 - 1);
							end if;

							-- State of the ram
							if w_addr = ram'HIGH then
								ram_filled <= true;
							end if;

							-- Move to next state
							if w_addr >= cfar_window or ram_filled then
								state <= read_cut;
							end if;
						end if;
						window_ptr <= g + 1;
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
						if window_ptr = g + 1 then -- Skip guard cells region 
							window_ptr <= window_ptr + 1;
							left_acc   <= (others => '0');
							rigth_acc  <= (others => '0');
						elsif window_ptr = g + 2 then -- Wait an extra cycle for data from ram
							window_ptr <= window_ptr + 1;
						elsif window_ptr < m + g + 3 then -- Window region
							window_ptr <= window_ptr + 1;
							left_acc   <= left_acc + signed(left_data);
							rigth_acc  <= rigth_acc + signed(rigth_data);
						elsif window_ptr = m + g + 3 then -- Sum of both window accumulation and next state
							state      <= cfar_ave;
							window_ptr <= g + 1;
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
						if window_ptr = g + 1 then -- get first sample in window and jump to last sample
							window_ptr <= m + g + 1;
						else
							window_ptr <= window_ptr + 1;
						end if;
						if window_ptr = m + g + 2 then
							left_acc   <= left_acc + signed(left_data);
							rigth_acc  <= rigth_acc - signed(rigth_data);
						elsif window_ptr = m + g + 3 then
							left_acc   <= left_acc - signed(left_data);
							rigth_acc  <= rigth_acc + signed(rigth_data);
						elsif window_ptr = m + g + 4 then
							state      <= cfar_ave;
							window_ptr <= g + 1;
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
						ave   <= total_acc * signed(DIVISORS(m));
						-- Next state
						state <= cfar_threshold;

					when cfar_threshold => -- Threshold
						threshold <= to_signed(5, ALPHA_WIDTH) * ave;
						-- Next state
						state     <= cfar_decision;

					when cfar_decision => -- CUT cfar_decision                    
						if resize(cut_value, threshold'LENGTH) >= threshold then
							o_data <= std_logic_vector(cut_value - 1);
							o_tag <= '1';
						else
							o_data <= std_logic_vector(cut_value);
							o_tag <= '0';
						end if;

						-- Next state
						state <= idle;
				end case;
			end if;
		end if;
	end process;

end Behavioral;
