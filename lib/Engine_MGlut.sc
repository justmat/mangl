Engine_MGlut : CroneEngine {
	classvar nvoices = 7;

	var pg;
	var effect;
	var <buffersL;
	var <buffersR;
	var <voices;
	var effectBus;
	var <phases;
	var <levels;

	var <seek_tasks;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// disk read
	readBuf { arg i, path;
		if(buffersL[i].notNil && buffersR[i].notNil, {
			if (File.exists(path), {
				var numChannels;
				var newbuf;

				numChannels = SoundFile.use(path.asString(), { |f| f.numChannels });

				newbuf = Buffer.readChannel(context.server, path, 0, -1, [0], { |b|
					voices[i].set(\buf_l, b);
					buffersL[i].free;
					buffersL[i] = b;
				});

				if (numChannels > 1, {
					newbuf = Buffer.readChannel(context.server, path, 0, -1, [1], { |b|
						voices[i].set(\buf_r, b);
						buffersR[i].free;
						buffersR[i] = b;
					});
				}, {
					voices[i].set(\buf_r, newbuf);
					buffersR[i].free;
					buffersR[i] = newbuf;
				});
			});
		});
	}

	alloc {
		buffersL = Array.fill(nvoices, { arg i;
			Buffer.alloc(
				context.server,
				context.server.sampleRate * 1,
			);
		});

		buffersR = Array.fill(nvoices, { arg i;
			Buffer.alloc(
				context.server,
				context.server.sampleRate * 1,
			);
		});

		SynthDef(\synth, {
			arg out, effectBus, phase_out, level_out, buf_l, buf_r,
			gate=0, pos=0, speed=1, jitter=0,
			size=0.1, density=20, density_mod_amt=0, pitch=1, spread=0, gain=1, envscale=1,
			freeze=0, t_reset_pos=0, cutoff=20000, q, mode=0, send=0;

			var grain_trig;
			var trig_rnd;
			var density_mod;
			var jitter_sig;
			var buf_dur;
			var pan_sig;
			var buf_pos;
			var pos_sig;
			var sig_l;
			var sig_r;
			var sig_mix;

			var env;
			var level;

      trig_rnd = LFNoise1.kr(density);
      density_mod = density * (2**(trig_rnd * density_mod_amt));
			grain_trig = Impulse.kr(density_mod);

			buf_dur = BufDur.kr(buf_l);

			pan_sig = TRand.kr(trig: grain_trig,
				lo: spread.neg,
				hi: spread);

			jitter_sig = TRand.kr(trig: grain_trig,
				lo: buf_dur.reciprocal.neg * jitter,
				hi: buf_dur.reciprocal * jitter);

			buf_pos = Phasor.kr(trig: t_reset_pos,
				rate: buf_dur.reciprocal / ControlRate.ir * speed,
				resetPos: pos);

			pos_sig = Wrap.kr(Select.kr(freeze, [buf_pos, pos]));

			sig_l = GrainBuf.ar(1, grain_trig, size, buf_l, pitch, pos_sig + jitter_sig, 2);
			sig_r = GrainBuf.ar(1, grain_trig, size, buf_r, pitch, pos_sig + jitter_sig, 2);

			sig_mix = Balance2.ar(sig_l, sig_r, pan_sig);

			sig_mix = BLowPass4.ar(sig_mix, cutoff, q);

			env = EnvGen.kr(Env.asr(1, 1, 1), gate: gate, timeScale: envscale);

			level = env;

			Out.ar(out, sig_mix * level * gain);
			Out.ar(effectBus, sig_mix * level * send);
			Out.kr(phase_out, pos_sig);
			// ignore gain for level out
			Out.kr(level_out, level);
		}).add;

		SynthDef(\effect, {
			arg in, out, delayTime=2.0, damp=0.1, size=4.0, diff=0.7, feedback=0.2, modDepth=0.1, modFreq=0.1, delayVol=1.0;
			var sig = In.ar(in, 2);
			sig = Greyhole.ar(sig, delayTime, damp, size, diff, feedback, modDepth, modFreq);
			Out.ar(out, sig * delayVol);
		}).add;

		context.server.sync;

		// delay bus
    effectBus = Bus.audio(context.server, 2);

		effect = Synth.new(\effect, [\in, effectBus.index, \out, context.out_b.index], target: context.xg);

		phases = Array.fill(nvoices, { arg i; Bus.control(context.server); });
		levels = Array.fill(nvoices, { arg i; Bus.control(context.server); });

		pg = ParGroup.head(context.xg);

		voices = Array.fill(nvoices, { arg i;
			Synth.new(\synth, [
				\out, context.out_b.index,
				\effectBus, effectBus.index,
				\phase_out, phases[i].index,
				\level_out, levels[i].index,
				\buf_l, buffersL[i],
				\buf_r, buffersR[i],
			], target: pg);
		});

		context.server.sync;

		this.addCommand("delay_time", "f", { arg msg; effect.set(\delayTime, msg[1]); });
		this.addCommand("delay_damp", "f", { arg msg; effect.set(\damp, msg[1]); });
		this.addCommand("delay_size", "f", { arg msg; effect.set(\size, msg[1]); });
		this.addCommand("delay_diff", "f", { arg msg; effect.set(\diff, msg[1]); });
		this.addCommand("delay_fdbk", "f", { arg msg; effect.set(\feedback, msg[1]); });
		this.addCommand("delay_mod_depth", "f", { arg msg; effect.set(\modDepth, msg[1]); });
		this.addCommand("delay_mod_freq", "f", { arg msg; effect.set(\modFreq, msg[1]); });
		this.addCommand("delay_volume", "f", { arg msg; effect.set(\delayVol, msg[1]); });

		this.addCommand("read", "is", { arg msg;
			this.readBuf(msg[1] - 1, msg[2]);
		});

		this.addCommand("seek", "if", { arg msg;
			var voice = msg[1] - 1;
			var lvl, pos;
			var seek_rate = 1 / 750;

			seek_tasks[voice].stop;

			// TODO: async get
			lvl = levels[voice].getSynchronous();

			if (false, { // disable seeking until fully implemented
				var step;
				var target_pos;

				// TODO: async get
				pos = phases[voice].getSynchronous();
				voices[voice].set(\freeze, 1);

				target_pos = msg[2];
				step = (target_pos - pos) * seek_rate;

				seek_tasks[voice] = Routine {
					while({ abs(target_pos - pos) > abs(step) }, {
						pos = pos + step;
						voices[voice].set(\pos, pos);
						seek_rate.wait;
					});

					voices[voice].set(\pos, target_pos);
					voices[voice].set(\freeze, 0);
					voices[voice].set(\t_reset_pos, 1);
				};

				seek_tasks[voice].play();
			}, {
				pos = msg[2];

				voices[voice].set(\pos, pos);
				voices[voice].set(\t_reset_pos, 1);
				voices[voice].set(\freeze, 0);
			});
		});

		this.addCommand("gate", "ii", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\gate, msg[2]);
		});

		this.addCommand("speed", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\speed, msg[2]);
		});

		this.addCommand("jitter", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\jitter, msg[2]);
		});

		this.addCommand("size", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\size, msg[2]);
		});

		this.addCommand("density", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\density, msg[2]);
		});

		this.addCommand("density_mod_amt", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\density_mod_amt, msg[2]);
		});

		this.addCommand("pitch", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\pitch, msg[2]);
		});

		this.addCommand("spread", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\spread, msg[2]);
		});

		this.addCommand("gain", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\gain, msg[2]);
		});

		this.addCommand("envscale", "if", { arg msg;
			var voice = msg[1] - 1;
			voices[voice].set(\envscale, msg[2]);
		});

		this.addCommand("cutoff", "if", { arg msg;
		var voice = msg[1] -1;
		voices[voice].set(\cutoff, msg[2]);
		});

		this.addCommand("q", "if", { arg msg;
		var voice = msg[1] -1;
		voices[voice].set(\q, msg[2]);
		});

		this.addCommand("send", "if", { arg msg;
		var voice = msg[1] -1;
		voices[voice].set(\send, msg[2]);
		});

		nvoices.do({ arg i;
			this.addPoll(("phase_" ++ (i+1)).asSymbol, {
				var val = phases[i].getSynchronous;
				val
			});

			this.addPoll(("level_" ++ (i+1)).asSymbol, {
				var val = levels[i].getSynchronous;
				val
			});
		});

		seek_tasks = Array.fill(nvoices, { arg i;
			Routine {}
		});
	}

	free {
		voices.do({ arg voice; voice.free; });
		phases.do({ arg bus; bus.free; });
		levels.do({ arg bus; bus.free; });
		buffersL.do({ arg b; b.free; });
		buffersR.do({ arg b; b.free; });
		effect.free;
		effectBus.free;
	}
}
