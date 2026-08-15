enum EegDeviceType {
  emotivEpocX(14, 256, 'Emotiv EPOC X'),
  emotivInsight(5, 128, 'Emotiv Insight'),
  emotivMn8(2, 128, 'Emotiv MN8'),
  muse(4, 256, 'Muse 2/S'),
  brainbit(4, 250, 'BrainBit'),
  openbci(8, 250, 'OpenBCI Cyton'),
  neurosky(1, 512, 'NeuroSky MindWave'),
  simulated(5, 128, 'Simulated Device');

  final int channelCount;
  final int sampleRate;
  final String displayName;

  const EegDeviceType(this.channelCount, this.sampleRate, this.displayName);
}
