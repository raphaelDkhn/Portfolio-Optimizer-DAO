mod optimizer_utils {
    use debug::PrintTrait;
    use option::OptionTrait;
    use array::{ArrayTrait, SpanTrait};
    use traits::{Into, TryInto, Index};
    use dict::Felt252DictTrait;
    use nullable::{NullableTrait, nullable_from_box, match_nullable, FromNullableResult};
    use orion::operators::tensor::{
        Tensor, TensorTrait, FP16x16Tensor, FP16x16TensorMul, FP16x16TensorSub, FP16x16TensorDiv
    };
    use orion::numbers::fixed_point::implementations::fp16x16::core::{
        FP16x16, FP16x16Add, FP16x16Div, FP16x16Mul, FP16x16Sub, FP16x16Impl
    };
    use orion::operators::tensor::core::ravel_index;
    use alexandria_data_structures::vec::{Felt252Vec, NullableVecImpl, NullableVec, VecTrait};


    impl Felt252DictNullableDrop of Drop<Felt252Dict<Nullable<FP16x16>>>;
    impl MutTensorDrop of Drop<MutTensor>;
    impl NullableVecDrop of Drop<NullableVec<FP16x16>>;
    impl NullableVecCopy of Copy<NullableVec<FP16x16>>;
    impl NullableDictCopy of Copy<Felt252Dict<Nullable<FP16x16>>>;

    struct MutTensor {
        shape: Span<usize>,
        data: NullableVec<FP16x16>,
    }

    #[generate_trait]
    impl FP16x16MutTensorImpl of MutTensorTrait {
        fn new(shape: Span<usize>, data: NullableVec<FP16x16>) -> MutTensor {
            MutTensor { shape, data }
        }

        fn at(ref self: @MutTensor, indices: Span<usize>) -> FP16x16 {
            assert(indices.len() == (*self.shape).len(), 'Indices do not match dimensions');
            let mut data = *self.data;
            NullableVecImpl::get(ref data, ravel_index(*self.shape, indices)).unwrap()
        }

        fn set(ref self: @MutTensor, indices: Span<usize>, value: FP16x16) {
            assert(indices.len() == (*self.shape).len(), 'Indices do not match dimensions');
            let mut data = *self.data;
            NullableVecImpl::set(ref data, ravel_index(*self.shape, indices), value)
        }

        fn to_tensor(ref self: @MutTensor, indices: Span<usize>) -> Tensor<FP16x16> {
            assert(indices.len() == (*self.shape).len(), 'Indices do not match dimensions');
            let mut tensor_data = ArrayTrait::<FP16x16>::new();
            let mut i: u32 = 0;
            let n = self.data.len();
            let mut data: NullableVec<FP16x16> = *self.data;
            loop {
                if i == n {
                    break ();
                }
                let mut x_i = data.at(i);
                tensor_data.append(x_i);
                i += 1;
            };
            return TensorTrait::<FP16x16>::new(*self.shape, tensor_data.span());
        }
    }


    #[derive(Copy, Drop)]
    struct Matrix {
        rows: usize,
        cols: usize,
        data: NullableVec<FP16x16>,
    }

    fn forward_elimination<
        impl FixedDict: Felt252DictTrait<FP16x16>, impl Vec: VecTrait<NullableVec<FP16x16>, usize>,
    >(
        ref matrix: Matrix, ref vector: NullableVec<FP16x16>, n: usize
    ) {
        let mut row: usize = 0;
        loop {
            if row == n {
                break;
            };

            let mut max_row = row;
            let mut i = row + 1;
            loop {
                if i == n {
                    break;
                };

                let mut lhs: FP16x16 = matrix.data.at(i * matrix.cols + row);
                let mut rhs: FP16x16 = matrix.data.at(max_row * matrix.cols + row);
                if lhs > rhs {
                    max_row = i
                };

                i += 1;
            };

            let mut matrix_new_val: FP16x16 = matrix.data.at(max_row);
            let mut matrix_old_val: FP16x16 = matrix.data.at(row);
            let mut vector_new_val: FP16x16 = vector.at(max_row);
            let mut vector_old_val: FP16x16 = vector.at(row);

            matrix.data.set(row, matrix_new_val);
            matrix.data.set(max_row, matrix_old_val);
            vector.set(row, vector_new_val);
            vector.set(max_row, vector_old_val);

            // Check for singularity
            let mut matrix_check_val: usize = row * matrix.cols + row;
            if matrix_check_val == 0 {
                panic(array!['Matrix is singular.'])
            }

            let mut i = row + 1;
            loop {
                if i == n {
                    break;
                };
                let factor = matrix.data.at(i * matrix.cols + row)
                    / matrix.data.at(row * matrix.cols + row);
                let mut j = row;
                loop {
                    if j == n {
                        break;
                    }
                    matrix
                        .data
                        .set(
                            matrix.data.at(i * matrix.cols + j),
                            matrix.data.at(i * matrix.cols + j)
                                - (factor * matrix.data.at(row * matrix.cols + j))
                        );
                    j += 1;
                };
                let mut vector_set_val: FP16x16 = vector.at(row);
                vector.set(vector.at(i), vector.at(i) - (factor * vector_set_val));
                i += 1;
            };
            row += 1;
        }
    }

    fn back_substitution<
        impl FixedDict: Felt252DictTrait<FP16x16>, impl Vec: VecTrait<NullableVec<FP16x16>, usize>,
    >(
        ref matrix: Matrix, ref vector: NullableVec<FP16x16>, n: usize
    ) -> Tensor<FP16x16> {
        // Initialize the vector for the tensor data
        let mut x_items: Felt252Dict<Nullable<FP16x16>> = Default::default();
        let mut x_data: NullableVec<FP16x16> = NullableVec { items: x_items, len: n };

        // Loop through the array and assign the values
        let mut i: usize = n - 1;
        loop {
            x_data.set(x_data.at(i), i);
            let mut j = i + 1;
            loop {
                if j == n {
                    break ();
                }
                let mut x_data_val_0: FP16x16 = matrix.data.at(i * matrix.cols + j) * x_data.at(j);
                x_data.set(x_data.at(i), x_data_val_0);
                j += 1;
            };
            let mut x_data_val_1: FP16x16 = x_data.at(i) / matrix.data.at(i * matrix.cols + i);
            x_data.set(x_data.at(i), x_data_val_1);
            if i == 0 {
                break ();
            }
            i -= 1;
        };

        // Map back the vector into a tensor
        let mut x_mut: @MutTensor = @MutTensor { shape: array![n].span(), data: x_data };
        let x = x_mut.to_tensor(indices: *x_mut.shape);
        return x;
    }

    fn linalg_solve<
        impl FixedDict: Felt252DictTrait<FP16x16>, impl Vec: VecTrait<NullableVec<FP16x16>, usize>,
    >(
        X: Tensor<FP16x16>, y: Tensor<FP16x16>
    ) -> Tensor<FP16x16> {
        // Assert X and y are the same length
        let n = *X.shape.at(0);
        assert(n == *y.shape.at(0), 'Matrix/vector dim mismatch');

        // Map X and y to Matrix and NullableVec objexts
        let mut x_items: Felt252Dict<Nullable<FP16x16>> = Default::default();
        let mut x_data: NullableVec<FP16x16> = NullableVec { items: x_items, len: n };
        let mut y_items: Felt252Dict<Nullable<FP16x16>> = Default::default();
        let mut y_data: NullableVec<FP16x16> = NullableVec { items: y_items, len: n };
        let mut i: usize = 0;
        loop {
            if i == n {
                break ();
            }
            let mut j: usize = 0;
            loop {
                if j == n {
                    break ();
                }
                x_data.set(i, *X.data.at(i));
                j += 1;
            };
            y_data.set(i, *y.data.at(i));
            i += 1;
        };
        let mut X_matrix = Matrix { rows: n, cols: n, data: x_data };

        let n = *y.shape.at(0);
        forward_elimination(ref X_matrix, ref y_data, n);
        return back_substitution(ref X_matrix, ref y_data, n);
    }

    fn test_tensor(X: Tensor::<FP16x16>) {
        'Testing tensor...'.print();
        'Len...'.print();
        X.data.len().print();

        // Print x by rows
        'Vals...'.print();
        let mut i = 0;
        loop {
            if i == *X.shape.at(0) {
                break ();
            }
            if X.shape.len() == 1 {
                let mut val = X.at(indices: array![i].span());
                val.mag.print();
            } else if X.shape.len() == 2 {
                let mut j = 0;
                loop {
                    if j == *X.shape.at(1) {
                        break ();
                    }
                    let mut val = X.at(indices: array![i, j].span());
                    val.mag.print();
                    j += 1;
                };
            } else {
                'Too many dims!'.print();
                break ();
            }
            i += 1;
        };
    }
}
