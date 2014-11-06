import planckStyle as s
from pylab import *
g = s.getSinglePlotter()
g.settings.norm_prob_label = r'P [${\rm eV}^{-1}$]'
g.settings.lineM = ['-b', '-r', '-g', '--b', '--r', '--g', '-c', '-y']

labels = [s.defplanck, '+lensing', '+BAO+$H_0$+JLA', s.planckall, '+lensing', '+BAO+$H_0$+JLA' ]
roots = [s.defdata, s.defdata + '_lensing', s.defdata + '_BAO_H070p6_JLA_lensing', s.defdata_all, s.defdata_all + '_lensing', s.defdata_all + '_BAO_H070p6_JLA_lensing' ]
roots = [g.getRoot('mnu', root) for root in roots]

g.plot_1d(roots, 'mnu', normalized=True)
g.add_legend(labels, legend_loc='upper right')

xlim([0, 1.2])

g.export()

