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

use std.textio.all;

entity CACFAR_cmplx is
	generic(
		DATA_WINDOW : natural := 512
	);
	port(
		clk    : in  std_logic;
		rst    : in  std_logic;
		i_cfar_window : in std_logic_vector(9 downto 0);
		i_cfar_window_we : in std_logic;
		we     : in  std_logic;
		i_data : in  std_logic_vector(38 downto 0);
		o_data : out std_logic_vector(23 downto 0)
	);
end CACFAR_cmplx;

architecture Behavioral of CACFAR_cmplx is
	
	component square_root
	  port (
	    aclk : in std_logic;
	    aresetn : in std_logic;
	    s_axis_cartesian_tvalid : in std_logic;
	    s_axis_cartesian_tdata : in std_logic_vector(47 downto 0);
	    m_axis_dout_tvalid : out std_logic;
	    m_axis_dout_tdata : out std_logic_vector(23 downto 0)
	  );
	end component;
	
	constant ALPHA_VALUE : natural := 5;

	-- FSM signals
	type states is (idle, read_cut, cfar_acc, fast_cfar_acc, cfar_magnitude, cfar_threshold, cfar_decision);
	signal state : states;

	-- RAM signals
	-- If complex input enabled we have twice ram amount
	constant ADDR_WIDTH : positive := positive(ceil(log2(real(DATA_WINDOW * 2))));
	type ram is array (0 to 2**ADDR_WIDTH - 1) of std_logic_vector(38 downto 0);
	signal cells        : ram      := (others => (others => '0'));
	signal w_addr       : integer range 0 to 2**ADDR_WIDTH - 1; -- write address
	signal left_data    : std_logic_vector(38 downto 0); -- read data port 1
	signal left_addr    : unsigned(ADDR_WIDTH - 1 downto 0); -- read address port 1 
	signal rigth_data   : std_logic_vector(38 downto 0); -- read data port 2
	signal rigth_addr   : unsigned(ADDR_WIDTH - 1 downto 0); -- read address port 2
	signal ram_filled   : boolean;

	constant DIV_COE_WIDTH : natural := 15;
	constant DIV_COE_FRACT_WIDTH : natural := 9;
	
	type DIV_COE_ARRAY is array (natural range <>) of unsigned(DIV_COE_WIDTH - 1 downto 0);
	
	function divCoeArrayInit(low, high, alpha : natural)
		return DIV_COE_ARRAY is
		variable rom : DIV_COE_ARRAY(low to high);
	begin
		for i in rom'range loop
			if i = 0 then
				rom(i) :=  to_unsigned(integer(real(alpha) * real(2 ** DIV_COE_FRACT_WIDTH)), DIV_COE_WIDTH);
			else
				rom(i) :=  to_unsigned(integer(real(alpha)/real(i*i) * real(2 ** DIV_COE_FRACT_WIDTH)), DIV_COE_WIDTH);
			end if;
		end loop;
		return rom;
	end function divCoeArrayInit;
	
	constant DIV_COE : DIV_COE_ARRAY := divCoeArrayInit(0, 512, ALPHA_VALUE ** 2);

	-- Internal signals
	constant ACC_GROWTH  : natural := natural(ceil(log2(real(512))));
	constant ALPHA_WIDTH : natural := natural(ceil(log2(real(5)))) + 1;
	signal read_cut_ctr  : integer range 0 to 1; -- Pointer within each window
	signal window_ptr    : integer range 3 to 10; -- Pointer within each window
	signal cut_addr      : unsigned(ADDR_WIDTH - 1 downto 0); -- Pointer to the current cell under test    
	signal cut_value_re     : signed(38 downto 0); -- Latch the value of the current cell under test
	signal cut_value_im     : signed(38 downto 0); -- Latch the value of the current cell under test
	signal left_acc_re      : signed(39 + ACC_GROWTH downto 0); -- Accumulator of the left window
	signal rigth_acc_re     : signed(39 + ACC_GROWTH downto 0); -- Accumulator of the rigth window
	signal total_acc_re     : signed(39 + ACC_GROWTH downto 0); -- Sum of window accumulators
	signal left_acc_im      : signed(39 + ACC_GROWTH downto 0); -- Accumulator of the left window
	signal rigth_acc_im     : signed(39 + ACC_GROWTH downto 0); -- Accumulator of the rigth window
	signal total_acc_im     : signed(39 + ACC_GROWTH downto 0); -- Sum of window accumulators
	signal threshold     : unsigned(2*(39 + ACC_GROWTH + 1) + DIV_COE_WIDTH - 1 downto 0);
	signal fast_ave_en   : boolean;
	signal complex_we : std_logic;
	signal flag_im      : std_logic;
	signal ave_magn : unsigned(2*(39 + ACC_GROWTH) + 1 downto 0);
	signal cut_magn : unsigned(78 downto 0);
	signal cfar_window : natural range 0 to 512;
	signal decision_valid : std_logic;
	signal decision_data : std_logic_vector(78 downto 0);
	signal m : natural range 0 to 255;
	signal g : natural range 0 to 255;
begin
	
	-- store window size
	process(clk)
	begin
		if rising_edge(clk) then
			if rst = '0' then
				cfar_window <= 12; -- some default value
			elsif i_cfar_window_we = '1' then
				cfar_window <= to_integer(unsigned(i_cfar_window));
			end if;
		end if;
	end process;
	
	m <= (cfar_window - 1) / 2 - 1;
	g <= (cfar_window - 2 * m - 1)/2 + 1;
	

	-- ram process
	ram_m : process(clk)
	begin
		if rising_edge(clk) then
			-- write port
			if we = '1' then
				cells(w_addr) <= i_data;
			end if;

			-- read ports
			left_data  <= cells(to_integer(left_addr)); -- Read port 1
			rigth_data <= cells(to_integer(rigth_addr)); -- Read port 2
		end if;
	end process;

	-- finite state machine process
	fsm_p : process(clk)
	begin
		if rising_edge(clk) then
			if rst = '0' then
				ram_filled   <= false;
				w_addr       <= 0;
				cut_addr     <= (others => '0');
				window_ptr   <= 3;
				left_addr    <= (others => '0');
				rigth_addr   <= (others => '0');
				read_cut_ctr <= 0;
				cut_value_re    <= (others => '0');
				left_acc_re     <= (others => '0');
				rigth_acc_re    <= (others => '0');
				total_acc_re    <= (others => '0');
				threshold    <= (others => '0');
				fast_ave_en  <= false;
				complex_we <= '0';
				flag_im <= '0';
			else
				case state is
					when idle =>
						if we = '1' then
							
							complex_we <= not complex_we;
							
							-- Update write address port
							if w_addr = ram'HIGH then
								w_addr <= ram'LOW;
							else
								w_addr <= w_addr + 1;
							end if;

							-- Update cut address
--							if w_addr >= 0 and w_addr < cfar_window then -- Corner cases
--								cut_addr  <= ram'HIGH + w_addr - cfar_window;
--								left_addr <= ram'HIGH + w_addr - cfar_window;
--								rigth_addr <= ram'HIGH + w_addr - (cfar_window - 1);
--							elsif w_addr = cfar_window then -- Wrap address
--								cut_addr  <= ram'LOW;
--								left_addr <= ram'LOW;
--								rigth_addr <= ram'low + 1;
--							else
								cut_addr  <= to_unsigned(w_addr - cfar_window, ADDR_WIDTH);
								left_addr <= to_unsigned(w_addr - cfar_window, ADDR_WIDTH);
								rigth_addr <= to_unsigned(w_addr - cfar_window - 1, ADDR_WIDTH);
--							end if;

							-- State of the ram
							if w_addr = ram'HIGH then
								ram_filled <= true;
							end if;

							-- Move to next state
							if (w_addr >= cfar_window*2 or ram_filled) and complex_we = '1' then
								state <= read_cut;
							end if;
						end if;
						decision_valid <= '0';
					when read_cut =>
						if read_cut_ctr = 0 then -- wait for the cycle that ram needs.
							read_cut_ctr <= read_cut_ctr + 1;
						elsif read_cut_ctr = 1 then -- Read cut value and move to next state
							read_cut_ctr <= 0;
							cut_value_re    <= signed(rigth_data);
							cut_value_im <= signed(left_data);
--							if fast_ave_en then
--								state <= fast_cfar_acc;
--							else
								state <= cfar_acc;
							--end if;
						end if;
						window_ptr <= g + 1;
					when cfar_acc =>    -- Update window pointer and accumulate data
						if window_ptr = g + 1 then -- Skip guard cells region 
							window_ptr <= window_ptr + 1;
							left_acc_re   <= (others => '0');
							rigth_acc_re  <= (others => '0');
							left_acc_im   <= (others => '0');
							rigth_acc_im  <= (others => '0');
						elsif window_ptr = g + 2 then -- Wait an extra cycle for data from ram
							window_ptr <= window_ptr + 1;
						elsif window_ptr < g + 2*m - 1 then -- Window region
							window_ptr <= window_ptr + 1;
							if flag_im = '0' then
								left_acc_re   <= left_acc_re + signed(left_data);
								rigth_acc_re  <= rigth_acc_re + signed(rigth_data);
							else
								left_acc_im   <= left_acc_im + signed(left_data);
								rigth_acc_im  <= rigth_acc_im + signed(rigth_data);
							end if;
						elsif window_ptr = g + 2*m - 1 then -- Sum of both window accumulation and next state
							flag_im <= not flag_im;
							if flag_im = '1' then
								state <= cfar_magnitude;
							end if;
							window_ptr <= g + 1;
							if flag_im = '0' then
								total_acc_re  <= left_acc_re + rigth_acc_re;
							else
								total_acc_im  <= left_acc_im + rigth_acc_im;
							end if;
						end if;

						if flag_im = '1' then
							-- Update read address port A
--							if cut_addr - 2*window_ptr < ram'LOW then
--								left_addr <= cut_addr + ram'HIGH - 2*window_ptr + 1; -- Corner case
--							else
								left_addr <= cut_addr - 2*window_ptr;
--							end if;
	
							-- Update read address port B
--							if cut_addr + window_ptr > ram'HIGH then
--								rigth_addr <= cut_addr - ram'HIGH + 2*window_ptr - 1; -- Corner case
--							else
								rigth_addr <= cut_addr - 2*window_ptr + 2*(m + 2*g + 1);
--							end if;
						else
							-- Update read address port A
--							if cut_addr - 2*window_ptr < ram'LOW then
--								left_addr <= cut_addr + ram'HIGH - 2*window_ptr; -- Corner case
--							else
								left_addr <= cut_addr - 2*window_ptr - 1;
--							end if;
	
							-- Update read address port B
--							if cut_addr + 2*window_ptr > ram'HIGH then
--								rigth_addr <= cut_addr - ram'HIGH + 2*window_ptr; -- Corner case
--							else
								rigth_addr <= cut_addr - 2*window_ptr - 1 + 2*(m + 2*g + 1);
							--end if;
						end if;
						fast_ave_en <= true;
					when fast_cfar_acc =>
						if window_ptr = g + 1 then
							window_ptr <= g + 1 + m;
						else
							window_ptr <= window_ptr + 1;
						end if;
						if window_ptr = g + m + 2 then
							if flag_im = '0' then
								left_acc_re   <= left_acc_re + signed(left_data);
								rigth_acc_re  <= rigth_acc_re - signed(rigth_data);
							else
								left_acc_im   <= left_acc_im + signed(left_data);
								rigth_acc_im  <= rigth_acc_im - signed(rigth_data);
							end if;
						elsif window_ptr = g + m + 3 then
							if flag_im = '0' then
								left_acc_re   <= left_acc_re - signed(left_data);
								rigth_acc_re  <= rigth_acc_re + signed(rigth_data);
							else
								left_acc_im   <= left_acc_im - signed(left_data);
								rigth_acc_im  <= rigth_acc_im + signed(rigth_data);
							end if;
						elsif window_ptr = g + m + 4 then
							flag_im <= not flag_im;
							if flag_im = '1' then
								state <= cfar_magnitude;
							end if;
							window_ptr <= g + 1;
							if flag_im = '0' then
								total_acc_re  <= left_acc_re + rigth_acc_re;
							else
								total_acc_im  <= left_acc_im + rigth_acc_im;
							end if;
						end if;
						
						-- Update read address port A
						if flag_im = '0' then
--							if cut_addr - 2*window_ptr < ram'LOW then
--								left_addr <= cut_addr + ram'HIGH - 2*window_ptr + 1; -- Corner case
--							else
								left_addr <= cut_addr - 2*window_ptr - 1;
--							end if;
	
							-- Update read address port B
--							if cut_addr + 2*window_ptr > ram'HIGH then
--								rigth_addr <= cut_addr - ram'HIGH + (2*window_ptr - 1) - 1; -- Corner case
--							else
								rigth_addr <= cut_addr + 2*window_ptr - 1 + 2*(m + 2*g + 1);
--							end if;
						else
--							if cut_addr - 2*window_ptr < ram'LOW then
--								left_addr <= cut_addr + ram'HIGH - 2*window_ptr + 1; -- Corner case
--							else
								left_addr <= cut_addr - 2*window_ptr;
--							end if;
	
							-- Update read address port B
--							if cut_addr + 2*window_ptr > ram'HIGH then
--								rigth_addr <= cut_addr - ram'HIGH + (2*window_ptr - 1) - 1; -- Corner case
--							else
								rigth_addr <= cut_addr + 2*window_ptr + 2*(m + 2*g + 1);
--							end if;
						end if;
					
					when cfar_magnitude =>
						ave_magn <= unsigned(total_acc_re * total_acc_re) + unsigned(total_acc_im * total_acc_im);
						cut_magn <= resize(unsigned(cut_value_re * cut_value_re) + unsigned(cut_value_im * cut_value_im), cut_magn'length);
						state <= cfar_threshold;

					when cfar_threshold => -- Threshold
						threshold <= ave_magn * DIV_COE(2*m);
						-- Next state
						state     <= cfar_decision;

					when cfar_decision => -- CUT cfar_decision                    
						if resize(cut_magn, threshold'LENGTH) >= threshold then
							decision_data <= std_logic_vector(cut_magn);
						else
							decision_data <= (others => '0');
						end if;
						decision_valid <= '1';
						-- Next state
						state <= idle;
				end case;
			end if;
		end if;
	end process;
	
	sqrt: square_root
		port map(
			aclk                    => clk,
			aresetn                 => rst,
			s_axis_cartesian_tvalid => decision_valid,
			s_axis_cartesian_tdata  => '0' & decision_data(78 downto 32),
			m_axis_dout_tvalid      => open,
			m_axis_dout_tdata       => o_data
		);

	
		
	fgd : block
		file ff : text open write_mode is "debug.log";
	begin
			
	process
		variable ln : line := null;
		
	begin
		wait on state;
		case state is 
			when idle => write(ln , string'("state -> Idle"));
			when read_cut => write(ln , string'("state -> read_cut"));
			when cfar_acc  | fast_cfar_acc=> 
				if state = cfar_acc then
					write(ln , string'("state -> cfar_acc"));
				else
					write(ln , string'("state -> fast_cfar_acc"));
				end if;
				writeline(ff, ln);
				write(ln, string'("cut_re"), right, 20);
				write(ln, string'("cut_im"), right, 20);
				writeline(ff, ln);
				write(ln, real(to_integer(cut_value_re))/real(2**30), RIGHT, 20, 6);
				write(ln, real(to_integer(cut_value_im))/real(2**30), RIGHT, 20, 6);
				writeline(ff, ln);
				write(ln , string'("window_ptr"), RIGHT, 10);
				write(ln , string'("flag_im"), RIGHT, 10);
				write(ln , string'("cut_addr"), RIGHT, 10);
				write(ln , string'("left_addr"), RIGHT, 10);
				write(ln , string'("rigth_addr"), RIGHT, 10);
				write(ln , string'("left_data"), RIGHT, 20);
				write(ln , string'("rigth_data"), RIGHT, 20);
				write(ln , string'("left_acc_re"), RIGHT, 20);
				write(ln , string'("left_acc_im"), RIGHT, 20);
				write(ln , string'("rigth_acc_re"), RIGHT, 20);
				write(ln , string'("rigth_acc_im"), RIGHT, 20);
				write(ln , string'("total_acc_re"), RIGHT, 20);
				write(ln , string'("total_acc_im"), RIGHT, 20);
			when cfar_magnitude =>
				write(ln , string'("state -> cfar_magnitude"));
				writeline(ff, ln);
				write(ln , string'("total_acc_re"), RIGHT, 20);
				write(ln , string'("total_acc_im"), RIGHT, 20);
			when cfar_threshold =>
				write(ln , string'("state -> cfar_threshold"));
			when cfar_decision =>
				write(ln , string'("state -> cfar_decision"));
		end case;
		writeline(ff, ln);
	end process;

	process(clk)
		variable ln : line;
	begin
		if rising_edge(clk) then
			case state is 
				when idle =>
					null;
				when read_cut =>
					null;
				when cfar_acc | fast_cfar_acc =>
					write(ln, window_ptr, RIGHT, 10);
					if flag_im = '1' then
						write(ln, 1, RIGHT, 10);
					else
						write(ln, 0, RIGHT, 10);
					end if;
					write(ln, to_integer(cut_addr), RIGHT, 10);
					write(ln, to_integer(left_addr), RIGHT, 10);
					write(ln, to_integer(rigth_addr), RIGHT, 10);
					write(ln, real(to_integer(signed(left_data)))/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(signed(rigth_data)))/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(left_acc_re) )/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(left_acc_im) )/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(rigth_acc_re))/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(rigth_acc_im))/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(total_acc_re))/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(total_acc_im))/real(2**30), RIGHT, 20, 6);
					writeline(ff, ln);
				when cfar_magnitude =>
					write(ln, real(to_integer(total_acc_re))/real(2**30), RIGHT, 20, 6);
					write(ln, real(to_integer(total_acc_im))/real(2**30), RIGHT, 20, 6);
					writeline(ff, ln);
				when cfar_threshold =>
					null;
				when cfar_decision =>
					null;
			end case;
		end if;
	end process;
	
	process
		variable ln : line := null;
	begin
		wait until decision_valid = '1';
		write(ln, string'("decision data: "));
		write(ln, to_integer(unsigned(decision_data(78 downto 32))));
		writeline(ff, ln);
	end process;
	
	
	end block fgd;
end Behavioral;
