% fsk_test_freq_est.m
% David Rowe April 2020

% test FSK frequency estimator, in particular at low Eb/No

fsk_lib;

function rx_bits = simple_fsk_demod(states, rx, f)
  M = states.M; Ts = states.Ts; Fs = states.Fs; N = states.nin;

  nsymb = states.nin/states.Ts;
  rx_filter = zeros(states.nin,M);
  rx_symbols = zeros(nsymb,M);

  % Down convert each tone. We can use any time index for down
  % conversion as it's non-coherent
  for m=1:M
     phase = exp(-j*2*pi*(1:N)'*f(m)/Fs);
     rx_filter(:,m) = rx .* phase;
  end

  % sum energy for each symbol
  for s=1:nsymb
    st_sym = (s-1)*Ts+1; en_sym = s*Ts;
    for m=1:M
      rx_symbols(s,m) = sum(rx_filter(st_sym:en_sym,m));
    end
  end

  % map symbols back to bits
  rx_bits = [];
  for s=1:nsymb
    [tone_max tone_index] = max(rx_symbols(s,:));
    arx_bits = dec2bin(tone_index - 1, states.bitspersymbol) - '0';
    rx_bits = [rx_bits arx_bits];
  end
  
end

% run a test at an Eb/No point, measure how many dud freq estimates using both algorithms
function [states f_log f_log2 num_dud1 num_dud2 ber ber2] = run_test(EbNodB = 10, num_frames=10)
  Fs = 8000;
  Rs = 100;
  M  = 4;
  bits_per_frame = 512;

  states = fsk_init(Fs,Rs,M);
  N = states.N;

  % complex signal
  states.tx_real = 0;

  states.tx_tone_separation = 250; % 2*states.Rs;
  states.ftx = 900 + states.tx_tone_separation*(1:M);
  states.fest_fmin = -Fs/2;
  states.fest_fmax = +Fs/2;
  %states.small_fft = 0;
  %states.Ndft = 2.^ceil(log2(N));
  %states.Sf = zeros(states.Ndft,1);

  EbNo = 10^(EbNodB/10);
  variance = states.Fs/(states.Rs*EbNo*states.bitspersymbol);

  nbits = bits_per_frame*num_frames;
  tx_bits = round(rand(1,nbits));
  tx = fsk_mod(states, tx_bits);
  noise = sqrt(variance/2)*randn(length(tx),1) + j*sqrt(variance/2)*randn(length(tx),1);
  rx = tx + noise;

  run_frames = floor(length(rx)/N)-1;
  st = 1; f_log = []; f_log2 = []; rx_bits = []; rx_bits2 = [];
  for f=1:run_frames

    % extract nin samples from input stream
    nin = states.nin;
    en = st + states.nin - 1;

    % due to nin variations it's possible to overrun buffer
    if en < length(rx)
      sf = rx(st:en);
      states = est_freq(states, sf, states.M);
      arx_bits = simple_fsk_demod(states, sf, states.f);
      rx_bits = [rx_bits arx_bits];
      arx_bits = simple_fsk_demod(states, sf, states.f2);
      rx_bits2 = [rx_bits2 arx_bits];
      f_log = [f_log; states.f]; f_log2 = [f_log2; states.f2];
      st += nin;
    end
  end

  % ignore start up transient
  startup = 1; % TODO make this sensible/proportional so its scales across Rs
  if num_frames > startup
    tx_bits = tx_bits(startup*bits_per_frame:end);
    rx_bits = rx_bits(startup*bits_per_frame:end);
    rx_bits2 = rx_bits2(startup*bits_per_frame:end);
  end
  
  % measure BER
  nerrors = sum(xor(tx_bits(1:length(rx_bits)),rx_bits)); ber = nerrors/nbits;
  nerrors2 = sum(xor(tx_bits(1:length(rx_bits2)),rx_bits2)); ber2 = nerrors2/nbits;
  
  % Lets say that for a valid freq estimate, all four tones must be within 0.1*Rs of their tx freqeuncy
  num_dud1 = 0; num_dud2 = 0;
  for i=1:length(f_log)
    if sum(abs(f_log(i,:)-states.ftx) > 0.1*states.Rs)
      num_dud1++;
    end
    if sum(abs(f_log2(i,:)-states.ftx) > 0.1*states.Rs)
      num_dud2++;
    end
  end
end

function run_single(EbNodB = 3, num_frames = 10)
  [states f_log f_log2 num_dud1 num_dud2 ber ber2] = run_test(EbNodB, num_frames);
  
  percent_dud1 = 100*num_dud1/length(f_log);
  percent_dud2 = 100*num_dud2/length(f_log);
  printf("EbNodB: %4.2f dB tests: %3d duds1: %3d %5.2f %% duds2: %3d %5.2f %% ber1: %4.3f ber2: %4.3f\n",
         EbNodB, length(f_log), num_dud1, percent_dud1, num_dud2, percent_dud2, ber, ber2)
  
  figure(1); clf;
  plot(f_log(:,1), 'linewidth', 2, 'b;peak;');
  hold on;
  plot(f_log(:,2:states.M), 'linewidth', 2, 'b');
  plot(f_log2(:,1),'linewidth', 2, 'r;mask;');
  plot(f_log2(:,2:states.M),'linewidth', 2, 'r');
  hold off;
  xlabel('Time (frames)'); ylabel('Frequency (Hz)');
  title(sprintf("EbNo = %4.2f dB", EbNodB));
  print("fsk_freq_est_single.png", "-dpng")

  figure(2); clf;
  errors = (f_log - states.ftx)(:);
  ind = find(abs(errors) < 100);
  errors2 = (f_log2 - states.ftx)(:);
  ind2 = find(abs(errors2) < 100);
  subplot(211); hist(errors(ind),50)
  subplot(212); hist(errors2(ind2),50)  
end

function run_curve

   EbNodB = 0:9;
   m4fsk_ber_theory = [0.23 0.18 0.14 0.09772 0.06156 0.03395 0.01579 0.00591 0.00168 3.39E-4];
   percent_log = []; ber_log = [];
   for ne = 1:length(EbNodB)
      [states f_log f_log2 num_dud1 num_dud2 ber ber2] = run_test(EbNodB(ne), 100);
      percent_dud1 = 100*num_dud1/length(f_log);
      percent_dud2 = 100*num_dud2/length(f_log);
      percent_log = [percent_log; [percent_dud1 percent_dud2]];
      ber_log = [ber_log; [ber ber2]];
      printf("EbNodB: %4.2f dB tests: %3d duds1: %3d %5.2f %% duds2: %3d %5.2f %% ber1: %4.4f ber2: %4.3f\n",
             EbNodB(ne), length(f_log), num_dud1, percent_dud1, num_dud2, percent_dud2, ber, ber2)
  end
  
  figure(1); clf; plot(EbNodB, percent_log(:,1), 'linewidth', 2, '+-;peak;'); grid;
  hold on;  plot(EbNodB, percent_log(:,2), 'linewidth', 2, 'r+-;mask;'); hold off;
  xlabel('Eb/No (dB)'); ylabel('% Errors');
  print("fsk_freq_est_errors.png", "-dpng")
  figure(2); clf; semilogy(EbNodB, m4fsk_ber_theory, 'linewidth', 2, 'bk+-;theory;'); grid;
  hold on;  semilogy(EbNodB, ber_log(:,1), 'linewidth', 2, '+-;peak;');
  semilogy(EbNodB, ber_log(:,2), 'linewidth', 2, 'r+-;mask;'); hold off;
  xlabel('Eb/No (dB)'); ylabel('BER');
  print("fsk_freq_est_ber.png", "-dpng")
end

graphics_toolkit("gnuplot");
more off;

% same results every time
rand('state',1); 
randn('state',1);

# choose one of these to run
run_single(0,10)
run_curve