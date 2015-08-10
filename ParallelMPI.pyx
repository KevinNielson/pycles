cimport mpi4py.mpi_c as mpi
cimport Grid
from time import time
import sys

import numpy as np
cimport numpy as np
import cython
from libc.math cimport fmin, fmax
cdef class ParallelMPI:
    def __init__(self,namelist):

        cdef:
            int is_initialized
            int ierr = 0

        #Check to see if MPI_Init has been called if not do so 
        ierr = mpi.MPI_Initialized(&is_initialized)
        if not is_initialized:
            from mpi4py import MPI

        self.comm_world =  mpi.MPI_COMM_WORLD

        ierr = mpi.MPI_Comm_rank(mpi.MPI_COMM_WORLD, &self.rank)
        ierr = mpi.MPI_Comm_size(mpi.MPI_COMM_WORLD, &self.size)



        cdef:
            int [3] cart_dims
            int [3] cyclic
            int ndims = 3
            int reorder = 1

        cart_dims[0] = namelist['mpi']['nprocx']
        cart_dims[1] = namelist['mpi']['nprocy']
        cart_dims[2] = namelist['mpi']['nprocz']

        cyclic[0] = 1
        cyclic[1] = 1
        cyclic[2] = 0

        #Create the cartesian world commmunicator
        ierr = mpi.MPI_Cart_create(self.comm_world,ndims, cart_dims, cyclic, reorder,&self.cart_comm_world)
        self.barrier()



        #Create the cartesian sub-communicators
        self.create_sub_communicators()
        self.barrier()


        return

    cpdef root_print(self,txt_output):
        if self.rank==0:
            print(txt_output)
        return

    cdef void kill(self):
        cdef int ierr = 0
        self.root_print("Terminating MPI!")
        ierr = mpi.MPI_Abort(self.comm_world,1)
        sys.exit()
        return

    cdef void barrier(self):
        mpi.MPI_Barrier(self.comm_world)
        return

    cdef void create_sub_communicators(self):
        cdef:
            int ierr = 0
            int [3] remains

        #Create the sub-communicator where x-dimension remains
        remains[0] = 1
        remains[1] = 0
        remains[2] = 0
        ierr = mpi.MPI_Cart_sub(self.cart_comm_world,remains, &self.cart_comm_sub_x)
        ierr =  mpi.MPI_Comm_size(self.cart_comm_sub_x, &self.sub_x_size)
        ierr =  mpi.MPI_Comm_rank(self.cart_comm_sub_x, &self.sub_x_rank)

        #Create the sub-communicator where the y-dimension remains
        remains[0] = 0
        remains[1] = 1
        remains[2] = 0
        ierr = mpi.MPI_Cart_sub(self.cart_comm_world,remains, &self.cart_comm_sub_y)
        ierr =  mpi.MPI_Comm_size(self.cart_comm_sub_y, &self.sub_y_size)
        ierr =  mpi.MPI_Comm_rank(self.cart_comm_sub_y, &self.sub_y_rank)

        #Create the sub communicator where the z-dimension remains
        remains[0] = 0
        remains[1] = 0
        remains[2] = 1
        ierr = mpi.MPI_Cart_sub(self.cart_comm_world,remains, &self.cart_comm_sub_z)
        ierr =  mpi.MPI_Comm_size(self.cart_comm_sub_z, &self.sub_z_size)
        ierr =  mpi.MPI_Comm_rank(self.cart_comm_sub_z, &self.sub_z_rank)

        #Create the sub communicator where x and y-dimension still remains
        remains[0] = 1
        remains[1] = 1
        remains[2] = 0
        ierr = mpi.MPI_Cart_sub(self.cart_comm_world,remains, &self.cart_comm_sub_xy)


        return


    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef double [:] HorizontalMean(self,Grid.Grid Gr,double *values):

        cdef:
            double [:] mean_local = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')
            double [:] mean = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')

            int i,j,k,ijk

            int imin = Gr.dims.gw
            int jmin = Gr.dims.gw
            int kmin = 0

            int imax = Gr.dims.nlg[0] - Gr.dims.gw
            int jmax = Gr.dims.nlg[1] - Gr.dims.gw
            int kmax = Gr.dims.nlg[2]

            int istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            int jstride = Gr.dims.nlg[2]

            int ishift, jshift

            double n_horizontal_i = 1.0/np.double(Gr.dims.n[1]*Gr.dims.n[0])

        with nogil:
            for i in xrange(imin,imax):
                ishift = i * istride
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        mean_local[k] += values[ijk]


        #Here we call MPI_Allreduce on the sub_xy communicator as we only need communication among
        #processes with the the same vertical rank

        mpi.MPI_Allreduce(&mean_local[0],&mean[0],Gr.dims.nlg[2],
                          mpi.MPI_DOUBLE,mpi.MPI_SUM,self.cart_comm_sub_xy)

        for i in xrange(Gr.dims.nlg[2]):
            mean[i] = mean[i]*n_horizontal_i


        return mean

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef double [:] HorizontalMeanofSquares(self,Grid.Grid Gr,const double *values1,const double *values2):

        cdef:
            double [:] mean_local = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')
            double [:] mean = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')

            int i,j,k,ijk

            int imin = Gr.dims.gw
            int jmin = Gr.dims.gw
            int kmin = 0

            int imax = Gr.dims.nlg[0] - Gr.dims.gw
            int jmax = Gr.dims.nlg[1] - Gr.dims.gw
            int kmax = Gr.dims.nlg[2]

            int istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            int jstride = Gr.dims.nlg[2]

            int ishift, jshift

            double n_horizontal_i = 1.0/np.double(Gr.dims.n[1]*Gr.dims.n[0])

        with nogil:
            for i in xrange(imin,imax):
                ishift = i * istride
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        mean_local[k] += values1[ijk]*values2[ijk]


        #Here we call MPI_Allreduce on the sub_xy communicator as we only need communication among
        #processes with the the same vertical rank

        mpi.MPI_Allreduce(&mean_local[0],&mean[0],Gr.dims.nlg[2],
                          mpi.MPI_DOUBLE,mpi.MPI_SUM,self.cart_comm_sub_xy)

        for i in xrange(Gr.dims.nlg[2]):
            mean[i] = mean[i]*n_horizontal_i


        return mean

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef double [:] HorizontalMeanofCubes(self,Grid.Grid Gr,const double *values1,const double *values2, const double *values3):

        cdef:
            double [:] mean_local = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')
            double [:] mean = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')

            int i,j,k,ijk

            int imin = Gr.dims.gw
            int jmin = Gr.dims.gw
            int kmin = 0

            int imax = Gr.dims.nlg[0] - Gr.dims.gw
            int jmax = Gr.dims.nlg[1] - Gr.dims.gw
            int kmax = Gr.dims.nlg[2]

            int istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            int jstride = Gr.dims.nlg[2]

            int ishift, jshift

            double n_horizontal_i = 1.0/np.double(Gr.dims.n[1]*Gr.dims.n[0])

        with nogil:
            for i in xrange(imin,imax):
                ishift = i * istride
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        mean_local[k] += values1[ijk]*values2[ijk]*values3[ijk]


        #Here we call MPI_Allreduce on the sub_xy communicator as we only need communication among
        #processes with the the same vertical rank

        mpi.MPI_Allreduce(&mean_local[0],&mean[0],Gr.dims.nlg[2],
                          mpi.MPI_DOUBLE,mpi.MPI_SUM,self.cart_comm_sub_xy)

        for i in xrange(Gr.dims.nlg[2]):
            mean[i] = mean[i]*n_horizontal_i


        return mean

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef double [:] HorizontalMaximum(self, Grid.Grid Gr, double *values):
        cdef:
            double [:] max_local = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')
            double [:] max = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')

            int i,j,k,ijk

            int imin = Gr.dims.gw
            int jmin = Gr.dims.gw
            int kmin = 0

            int imax = Gr.dims.nlg[0] - Gr.dims.gw
            int jmax = Gr.dims.nlg[1] - Gr.dims.gw
            int kmax = Gr.dims.nlg[2]

            int istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            int jstride = Gr.dims.nlg[2]

            int ishift, jshift

            double n_horizontal_i = 1.0/np.double(Gr.dims.n[1]*Gr.dims.n[0])

        with nogil:
            for k in xrange(kmin,kmax):
                max_local[k] = -9e12

            for i in xrange(imin,imax):
                ishift = i * istride
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        max_local[k] = fmax(max_local[k],values[ijk])

        mpi.MPI_Allreduce(&max_local[0],&max[0],Gr.dims.nlg[2],
                          mpi.MPI_DOUBLE,mpi.MPI_MAX,self.cart_comm_sub_xy)

        return max


    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef double [:] HorizontalMinimum(self, Grid.Grid Gr, double *values):
        cdef:
            double [:] min_local = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')
            double [:] min = np.zeros(Gr.dims.nlg[2],dtype=np.double,order='c')

            int i,j,k,ijk

            int imin = Gr.dims.gw
            int jmin = Gr.dims.gw
            int kmin = 0

            int imax = Gr.dims.nlg[0] - Gr.dims.gw
            int jmax = Gr.dims.nlg[1] - Gr.dims.gw
            int kmax = Gr.dims.nlg[2]

            int istride = Gr.dims.nlg[1] * Gr.dims.nlg[2]
            int jstride = Gr.dims.nlg[2]

            int ishift, jshift

            double n_horizontal_i = 1.0/np.double(Gr.dims.n[1]*Gr.dims.n[0])

        with nogil:
            for k in xrange(kmin,kmax):
                min_local[k] = 9e12

            for i in xrange(imin,imax):
                ishift = i * istride
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        min_local[k] = fmin(min_local[k],values[ijk])

        mpi.MPI_Allreduce(&min_local[0],&min[0],Gr.dims.nlg[2],
                          mpi.MPI_DOUBLE,mpi.MPI_MIN,self.cart_comm_sub_xy)

        return min

cdef class Pencil:


    def __init__(self):
        pass

    cpdef initialize(self, Grid.Grid Gr, ParallelMPI Pa, int dim):

        self.dim = dim
        self.n_local_values = Gr.dims.npl

        cdef:
            int remainder = 0
            int i

        if dim==0:
            self.size = Pa.sub_x_size
            self.rank = Pa.sub_x_rank
            self.n_total_pencils = Gr.dims.nl[1] * Gr.dims.nl[2]
            self.pencil_length = Gr.dims.n[0]
        elif dim==1:
            self.size = Pa.sub_y_size
            self.rank = Pa.sub_y_rank
            self.n_total_pencils = Gr.dims.nl[0] * Gr.dims.nl[2]
            self.pencil_length = Gr.dims.n[1]
        elif dim==2:
            self.size = Pa.sub_z_size
            self.rank = Pa.sub_z_rank
            self.n_total_pencils = Gr.dims.nl[0] * Gr.dims.nl[1]
            self.pencil_length = Gr.dims.n[2]
        else:
            Pa.root_print('Pencil dim='+ str(dim) + 'not valid')
            Pa.root_print('Killing simuulation')
            Pa.kill()

        remainder =  self.n_total_pencils%self.size
        self.n_pencil_map = np.empty((self.size,),dtype=np.int,order='c')


        self.n_pencil_map[:] = self.n_total_pencils//self.size
        for i in xrange(self.size):
            if i < remainder:
                self.n_pencil_map[i] += 1

        self.n_local_pencils = self.n_pencil_map[self.rank]


        self.nl_map = np.empty((self.size),dtype=np.int,order='c')
        self.send_counts = np.empty((self.size),dtype=np.intc,order='c')
        self.recv_counts = np.empty((self.size),dtype=np.intc,order='c')
        self.rdispls = np.zeros((self.size),dtype=np.intc,order='c')
        self.sdispls = np.zeros((self.size),dtype=np.intc,order='c')

        #Now need to communicate number of local points on each process
        if self.dim==0:
            mpi.MPI_Allgather(&Gr.dims.nl[0],1,mpi.MPI_LONG,&self.nl_map[0],1,mpi.MPI_LONG,Pa.cart_comm_sub_x)

            #Now compute the send counts
            for i in xrange(self.size):
                self.send_counts[i] = Gr.dims.nl[0] * self.n_pencil_map[i]
                self.recv_counts[i] = self.n_local_pencils * self.nl_map[i]
        elif self.dim==1:
            mpi.MPI_Allgather(&Gr.dims.nl[1],1,mpi.MPI_LONG,&self.nl_map[0],1,mpi.MPI_LONG,Pa.cart_comm_sub_y)
            #Now compute the send counts
            for i in xrange(self.size):
                self.send_counts[i] = Gr.dims.nl[1] * self.n_pencil_map[i]
                self.recv_counts[i] = self.n_local_pencils * self.nl_map[i]
        else:
            mpi.MPI_Allgather(&Gr.dims.nl[2],1,mpi.MPI_LONG,&self.nl_map[0],1,mpi.MPI_LONG,Pa.cart_comm_sub_z)
            #Now compute the send counts
            for i in xrange(self.size):
                self.send_counts[i] = Gr.dims.nl[2] * self.n_pencil_map[i]
                self.recv_counts[i] = self.n_local_pencils * self.nl_map[i]



        #Compute the send and receive displacments
        for i in xrange(self.size-1):
            self.sdispls[i+1] = self.sdispls[i] + self.send_counts[i]
            self.rdispls[i+1] = self.rdispls[i] + self.recv_counts[i]

        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef double [:,:] forward_double(self, Grid.DimStruct *dims, ParallelMPI Pa ,double *data):

        cdef:
            double [:] local_transpose = np.empty((dims.npl,),dtype=np.double,order='c')
            double [:] recv_buffer = np.empty((self.n_local_pencils * self.pencil_length),dtype=np.double,order='c')
            double [:,:] pencils = np.empty((self.n_local_pencils,self.pencil_length),dtype=np.double,order='c')


        #Build send buffer
        self.build_buffer_double(dims, data, &local_transpose[0])

        if(self.size > 1):
            #Do all to all communication
            if self.dim == 0:
                mpi.MPI_Alltoallv(&local_transpose[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE,
                            &recv_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE,Pa.cart_comm_sub_x)
            elif self.dim==1:
                mpi.MPI_Alltoallv(&local_transpose[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE,
                            &recv_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE,Pa.cart_comm_sub_y)
            else:
                mpi.MPI_Alltoallv(&local_transpose[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE,
                            &recv_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE,Pa.cart_comm_sub_z)


            self.unpack_buffer_double(dims,&recv_buffer[0],pencils)

        else:
            self.unpack_buffer_double(dims,&local_transpose[0],pencils)

        return pencils

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void build_buffer_double(self, Grid.DimStruct *dims, double *data, double *local_transpose ):

        cdef:
            long imin = dims.gw
            long jmin = dims.gw
            long kmin = dims.gw

            long imax = dims.nlg[0] - dims.gw
            long jmax = dims.nlg[1] - dims.gw
            long kmax = dims.nlg[2] - dims.gw
            long istride, jstride, kstride
            long istride_nogw, jstride_nogw, kstride_nogw
            long ishift, jshift, kshift
            long ishift_nogw, jshift_nogw, kshift_nogw

            long i,j,k,ijk,ijk_no_gw

        if self.dim == 0:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = 1
            jstride_nogw = dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        elif self.dim ==1:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1]
            jstride_nogw = 1 #dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        else:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1] * dims.nl[2]
            jstride_nogw = dims.nl[2]
            kstride_nogw = 1

        #Build the local buffer
        with nogil:
            for i in xrange(imin,imax):
                ishift = i*istride
                ishift_nogw = (i-dims.gw) * istride_nogw
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    jshift_nogw = (j-dims.gw) * jstride_nogw
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        ijk_no_gw = ishift_nogw + jshift_nogw+ (k-dims.gw)*kstride_nogw
                        local_transpose[ijk_no_gw] = data[ijk]



        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void unpack_buffer_double(self,Grid.DimStruct *dims, double *recv_buffer, double  [:,:] pencils):

        cdef:
            long m, p, i
            long nl_shift, count


        #Loop over the number of processors in the rank
        count = 0
        for m in xrange(self.size):

            if m == 0:
                nl_shift = 0
            else:
                nl_shift += self.nl_map[m-1]

            #Loop over the number of local pencils
            with nogil:
                for p in xrange(self.n_local_pencils):
                    #Now loop over the number of points in each pencil from the m-th processor
                    for i in xrange(self.nl_map[m]):
                        pencils[p,nl_shift + i] = recv_buffer[count]
                        count += 1


        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void reverse_double(self, Grid.DimStruct *dims, ParallelMPI Pa, double [:,:] pencils, double *data):

        cdef:
            double [:] send_buffer = np.empty(self.n_local_pencils * self.pencil_length,dtype=np.double,order='c')
            double [:] recv_buffer = np.empty(dims.npl,dtype=np.double,order='c')

        #This is exactly the inverse operation to forward_double so that the send_counts can be used as the recv_counts
        #and vice versa

        self.reverse_build_buffer_double(dims,pencils,&send_buffer[0])



        if(self.size > 1):
            #Do all to all communication
            if self.dim == 0:
                mpi.MPI_Alltoallv(&send_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE,
                            &recv_buffer[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE,Pa.cart_comm_sub_x)

            elif self.dim==1:
                mpi.MPI_Alltoallv(&send_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE,
                            &recv_buffer[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE,Pa.cart_comm_sub_y)
            else:
                mpi.MPI_Alltoallv(&send_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE,
                            &recv_buffer[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE,Pa.cart_comm_sub_z)

            self.reverse_unpack_buffer_double(dims,&recv_buffer[0],&data[0])

        else:
            self.reverse_unpack_buffer_double(dims,&send_buffer[0],&data[0])


        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void reverse_build_buffer_double(self, Grid.DimStruct *dims, double [:,:] pencils, double *send_buffer):
        cdef:
            long m, p, i
            long nl_shift, count


        #Loop over the number of processors in the rank
        count = 0
        for m in xrange(self.size):

            if m == 0:
                nl_shift = 0
            else:
                nl_shift += self.nl_map[m-1]

            #Loop over the number of local pencils
            with nogil:
                for p in xrange(self.n_local_pencils):
                    #Now loop over the number of points in each pencil from the m-th processor
                    for i in xrange(self.nl_map[m]):
                        send_buffer[count] = pencils[p,nl_shift + i]
                        count += 1


        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void reverse_unpack_buffer_double(self, Grid.DimStruct *dims, double *recv_buffer, double *data ):

        cdef:
            long imin = dims.gw
            long jmin = dims.gw
            long kmin = dims.gw

            long imax = dims.nlg[0] - dims.gw
            long jmax = dims.nlg[1] - dims.gw
            long kmax = dims.nlg[2] - dims.gw
            long istride, jstride, kstride
            long istride_nogw, jstride_nogw, kstride_nogw
            long ishift, jshift, kshift
            long ishift_nogw, jshift_nogw, kshift_nogw

            long i,j,k,ijk,ijk_no_gw

        if self.dim == 0:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = 1
            jstride_nogw = dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        elif self.dim ==1:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1]
            jstride_nogw = 1 #dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        else:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1] * dims.nl[2]
            jstride_nogw = dims.nl[2]
            kstride_nogw = 1


        #Build the local buffer
        with nogil:
            for i in xrange(imin,imax):
                ishift = i*istride
                ishift_nogw = (i-dims.gw) * istride_nogw
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    jshift_nogw = (j-dims.gw) * jstride_nogw
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        ijk_no_gw = ishift_nogw + jshift_nogw+ (k-dims.gw)*kstride_nogw
                        data[ijk] = recv_buffer[ijk_no_gw]

        return


    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void build_buffer_complex(self, Grid.DimStruct *dims, complex *data, complex *local_transpose ):

        cdef:
            long imin = dims.gw
            long jmin = dims.gw
            long kmin = dims.gw

            long imax = dims.nlg[0] - dims.gw
            long jmax = dims.nlg[1] - dims.gw
            long kmax = dims.nlg[2] - dims.gw
            long istride, jstride, kstride
            long istride_nogw, jstride_nogw, kstride_nogw
            long ishift, jshift, kshift
            long ishift_nogw, jshift_nogw, kshift_nogw

            long i,j,k,ijk,ijk_no_gw

        if self.dim == 0:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = 1
            jstride_nogw = dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        elif self.dim ==1:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1]
            jstride_nogw = 1 #dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        else:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1] * dims.nl[2]
            jstride_nogw = dims.nl[2]
            kstride_nogw = 1

        #Build the local buffer
        with nogil:
            for i in xrange(imin,imax):
                ishift = i*istride
                ishift_nogw = (i-dims.gw) * istride_nogw
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    jshift_nogw = (j-dims.gw) * jstride_nogw
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        ijk_no_gw = ishift_nogw + jshift_nogw+ (k-dims.gw)*kstride_nogw
                        local_transpose[ijk_no_gw] = data[ijk]



        return


    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void unpack_buffer_complex(self,Grid.DimStruct *dims, complex *recv_buffer, complex  [:,:] pencils):

        cdef:
            long m, p, i
            long nl_shift, count


        #Loop over the number of processors in the rank
        count = 0
        for m in xrange(self.size):

            if m == 0:
                nl_shift = 0
            else:
                nl_shift += self.nl_map[m-1]

            #Loop over the number of local pencils
            with nogil:
                for p in xrange(self.n_local_pencils):
                    #Now loop over the number of points in each pencil from the m-th processor
                    for i in xrange(self.nl_map[m]):
                        pencils[p,nl_shift + i] = recv_buffer[count]
                        count += 1


        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef complex [:,:] forward_complex(self, Grid.DimStruct *dims, ParallelMPI Pa ,complex *data):

        cdef:
            complex [:] local_transpose = np.empty((dims.npl,),dtype=np.complex,order='c')
            complex [:] recv_buffer = np.empty((self.n_local_pencils * self.pencil_length),dtype=np.complex,order='c')
            complex [:,:] pencils = np.empty((self.n_local_pencils,self.pencil_length),dtype=np.complex,order='c')


        #Build send buffer
        self.build_buffer_complex(dims, data, &local_transpose[0])

        if(self.size > 1):
            #Do all to all communication
            if self.dim == 0:
                mpi.MPI_Alltoallv(&local_transpose[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE_COMPLEX,
                            &recv_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE_COMPLEX,Pa.cart_comm_sub_x)
            elif self.dim==1:
                mpi.MPI_Alltoallv(&local_transpose[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE_COMPLEX,
                            &recv_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE_COMPLEX,Pa.cart_comm_sub_y)
            else:
                mpi.MPI_Alltoallv(&local_transpose[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE_COMPLEX,
                            &recv_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE_COMPLEX,Pa.cart_comm_sub_z)


            self.unpack_buffer_complex(dims,&recv_buffer[0],pencils)

        else:
            self.unpack_buffer_complex(dims,&local_transpose[0],pencils)

        return pencils

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void reverse_complex(self, Grid.DimStruct *dims, ParallelMPI Pa, complex [:,:] pencils, complex *data):

        cdef:
            complex [:] send_buffer = np.empty(self.n_local_pencils * self.pencil_length,dtype=np.complex,order='c')
            complex [:] recv_buffer = np.empty(dims.npl,dtype=np.complex,order='c')

        #This is exactly the inverse operation to forward_double so that the send_counts can be used as the recv_counts
        #and vice versa
        self.reverse_build_buffer_complex(dims,pencils,&send_buffer[0])
        if(self.size > 1):
            #Do all to all communication
            if self.dim == 0:
                mpi.MPI_Alltoallv(&send_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE_COMPLEX,
                            &recv_buffer[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE_COMPLEX,Pa.cart_comm_sub_x)
            elif self.dim==1:
                mpi.MPI_Alltoallv(&send_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE_COMPLEX,
                            &recv_buffer[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE_COMPLEX,Pa.cart_comm_sub_y)
            else:

                mpi.MPI_Alltoallv(&send_buffer[0], &self.recv_counts[0], &self.rdispls[0],mpi.MPI_DOUBLE_COMPLEX,
                            &recv_buffer[0], &self.send_counts[0], &self.sdispls[0],mpi.MPI_DOUBLE_COMPLEX,Pa.cart_comm_sub_z)

            self.reverse_unpack_buffer_complex(dims,&recv_buffer[0],data)
        else:
            self.reverse_unpack_buffer_complex(dims,&send_buffer[0],data)

        return


    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void reverse_build_buffer_complex(self, Grid.DimStruct *dims, complex [:,:] pencils, complex *send_buffer):
        cdef:
            long m, p, i
            long nl_shift, count


        #Loop over the number of processors in the rank
        count = 0
        for m in xrange(self.size):

            if m == 0:
                nl_shift = 0
            else:
                nl_shift += self.nl_map[m-1]

            #Loop over the number of local pencils
            with nogil:
                for p in xrange(self.n_local_pencils):
                    #Now loop over the number of points in each pencil from the m-th processor
                    for i in xrange(self.nl_map[m]):
                        send_buffer[count] = pencils[p,nl_shift + i]
                        count += 1


        return

    @cython.boundscheck(False)  #Turn off numpy array index bounds checking
    @cython.wraparound(False)   #Turn off numpy array wrap around indexing
    @cython.cdivision(True)
    cdef void reverse_unpack_buffer_complex(self, Grid.DimStruct *dims, complex *recv_buffer, complex *data ):

        cdef:
            long imin = dims.gw
            long jmin = dims.gw
            long kmin = dims.gw

            long imax = dims.nlg[0] - dims.gw
            long jmax = dims.nlg[1] - dims.gw
            long kmax = dims.nlg[2] - dims.gw
            long istride, jstride, kstride
            long istride_nogw, jstride_nogw, kstride_nogw
            long ishift, jshift, kshift
            long ishift_nogw, jshift_nogw, kshift_nogw

            long i,j,k,ijk,ijk_no_gw

        if self.dim == 0:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = 1
            jstride_nogw = dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        elif self.dim ==1:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1]
            jstride_nogw = 1 #dims.nl[0]
            kstride_nogw = dims.nl[0] * dims.nl[1]
        else:
            istride = dims.nlg[1] * dims.nlg[2]
            jstride = dims.nlg[2]
            kstride = 1

            istride_nogw = dims.nl[1] * dims.nl[2]
            jstride_nogw = dims.nl[2]
            kstride_nogw = 1


        #Build the local buffer
        with nogil:
            for i in xrange(imin,imax):
                ishift = i*istride
                ishift_nogw = (i-dims.gw) * istride_nogw
                for j in xrange(jmin,jmax):
                    jshift = j * jstride
                    jshift_nogw = (j-dims.gw) * jstride_nogw
                    for k in xrange(kmin,kmax):
                        ijk = ishift + jshift + k
                        ijk_no_gw = ishift_nogw + jshift_nogw+ (k-dims.gw)*kstride_nogw
                        data[ijk] = recv_buffer[ijk_no_gw]

        return