cimport ParallelMPI as ParallelMPI
cimport PrognosticVariables as PrognosticVariables
cimport Grid as Grid
cimport mpi4py.mpi_c as mpi

import numpy as np
cimport numpy as np

import cython
from libc.math cimport fmin, fmax, fabs

cdef class TimeStepping:

    def __init__(self):

        return


    cpdef initialize(self,namelist,PrognosticVariables.PrognosticVariables PV, ParallelMPI.ParallelMPI Pa):

        #Get the time stepping potions from the name list
        try:
            self.ts_type = namelist['time_stepping']['ts_type']
        except:
            Pa.root_print('ts_type not given in namelist')
            Pa.root_print('Killing simulation now')
            Pa.kill()

        try:
            self.dt = namelist['time_stepping']['dt_initial']
        except:
            Pa.root_print('dt_initial (initial time step) not given in namelist so taking defualt value dt_initail = 1.0')
            self.dt = 1.0

        try:
            self.dt_max = namelist['time_stepping']['dt_max']
        except:
            Pa.root_print('dt_max (maximum permissible time step) not given in namelist so taking default value dt_max =10.0')
            self.dt_max = 10.0

        try:
            self.t = namelist['time_stepping']['t']
        except:
            Pa.root_print('t (initial time) not given in namelist so taking default value t = 0')
            self.t = 0.0

        try:
            self.cfl_limit = namelist['time_stepping']['cfl_limit']
        except:
            Pa.root_print('cfl_limit (maximum permissible cfl number) not given in namelist so taking default value cfl_max=0.7')
            self.cfl_limit = 0.7

        try:
            self.t_max = namelist['time_stepping']['t_max']
        except:
            Pa.root_print('t_max (time at end of simulation) not given in name list! Killing Simulation Now')
            Pa.kill()


        #Now initialize the correct time stepping routine
        if self.ts_type == 2:
            self.initialize_second(PV)
        elif self.ts_type == 3:
            self.initialize_third(PV)
        else:
            Pa.root_print('Invalid ts_type: ' + str(self.ts_type))
            Pa.root_print('Killing simulation now')
            Pa.kill()


        return


    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cpdef update(self, Grid.Grid Gr, PrognosticVariables.PrognosticVariables PV, ParallelMPI.ParallelMPI Pa):

        if self.ts_type == 2:
            self.update_second(Gr,PV)
        elif self.ts_type == 3:
            self.update_third(Gr,PV)

        #Compute the CFL number and diffusive stability criterion
        if self.rk_step == self.n_rk_steps - 1:
            self.compute_cfl_max(Gr, PV, Pa)
            self.dt = self.cfl_time_step()

            #Diffusive limiting not yet implemented
            if self.t + self.dt > self.t_max:
                self.dt = self.t_max - self.t


        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cpdef update_second(self, Grid.Grid Gr, PrognosticVariables.PrognosticVariables PV):

        cdef:
            int i


        if self.rk_step == 0:
            for i in xrange(Gr.dims.npg*PV.nv):
                self.value_copies[0,i] = PV.values[i]
                PV.values[i] += PV.tendencies[i]*self.dt
                PV.tendencies[i] = 0.0
        else:
            for i in xrange(Gr.dims.npg*PV.nv):
                PV.values[i] = 0.5 * (self.value_copies[0,i] + PV.values[i] + PV.tendencies[i] * self.dt)
                PV.tendencies[i] = 0.0
            self.t += self.dt

        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cpdef update_third(self, Grid.Grid Gr, PrognosticVariables.PrognosticVariables PV):

        cdef:
            int i


        if self.rk_step == 0:
            for i in xrange(Gr.dims.npg*PV.nv):
                self.value_copies[0,i] = PV.values[i]
                PV.values[i] += PV.tendencies[i]*self.dt
                PV.tendencies[i] = 0.0
        elif self.rk_step == 1:
            for i in xrange(Gr.dims.npg*PV.nv):
                PV.values[i] = 0.75 * self.value_copies[0,i] +  0.25*(PV.values[i] + PV.tendencies[i]*self.dt)
                PV.tendencies[i] = 0.0
        else:
            for i in xrange(Gr.dims.npg*PV.nv):
                PV.values[i] = (1.0/3.0) * self.value_copies[0,i] + (2.0/3.0)*(PV.values[i] + PV.tendencies[i]*self.dt)
                PV.tendencies[i] = 0.0
            self.t += self.dt

        return



    cdef void initialize_second(self,PrognosticVariables.PrognosticVariables PV):

        self.rk_step = 0
        self.n_rk_steps = 2

        #Now initialize storage
        self.value_copies = np.zeros((1,PV.values.shape[0]),dtype=np.double,order='c')
        self.tendency_copies = None

        return


    cdef void initialize_third(self,PrognosticVariables.PrognosticVariables PV):

        self.rk_step = 0
        self.n_rk_steps = 3

        #Now initialize storage
        self.value_copies = np.zeros((1,PV.values.shape[0]),dtype=np.double,order='c')
        self.tendency_copies = None

        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void compute_cfl_max(self,Grid.Grid Gr, PrognosticVariables.PrognosticVariables PV, ParallelMPI.ParallelMPI Pa):

        cdef:
            double cfl_max_local = -9999.0
            double [3] dxi = Gr.dims.dxi
            long u_shift = PV.get_varshift(Gr,'u')
            long v_shift = PV.get_varshift(Gr,'v')
            long w_shift = PV.get_varshift(Gr,'w')

            long imin = Gr.dims.gw
            long jmin = Gr.dims.gw
            long kmin = Gr.dims.gw

            long imax = Gr.dims.nlg[0] - Gr.dims.gw
            long jmax = Gr.dims.nlg[1] - Gr.dims.gw
            long kmax = Gr.dims.nlg[2] - Gr.dims.gw

            long istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            long jstride = Gr.dims.nlg[1]
            long i,j,k, ijk, ishift, jshift

        with nogil:
            for i in xrange(imin,imax):
                ishift = i * istride
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        cfl_max_local = fmax(cfl_max_local, self.dt * (fabs(PV.values[u_shift + ijk])*dxi[0] + fabs(PV.values[v_shift+ijk])*dxi[1] + fabs(PV.values[w_shift+ijk])*dxi[2]))



        mpi.MPI_Allreduce(&cfl_max_local,&self.cfl_max,1,
                          mpi.MPI_DOUBLE,mpi.MPI_MAX,Pa.comm_world)

        self.cfl_max += 1e-11


        return


    cdef inline double cfl_time_step(self):
        cdef double exact = fmin(self.dt_max,self.cfl_limit/(self.cfl_max/self.dt))
        return fmin(exact, self.dt_max)

